#!/usr/bin/env python3
"""Writes Keeper roster CSVs for NHL teams, from the NHL's own public API.

    ./tools/nhl-rosters.py WPG MTL        # two teams
    ./tools/nhl-rosters.py --all          # every team in the league right now
    ./tools/nhl-rosters.py --all -o ~/Rosters

Why a script rather than a folder of CSVs: an NHL roster is accurate for about a
week. Trades, call-ups and waivers move numbers constantly, and a stale roster in
Keeper doesn't fail loudly — it files footage under the wrong player and writes the
wrong name into the filename. Fetching on the day is the only version that's right.

Nothing outside the standard library, so it runs on a stock Mac with no setup.
"""

import argparse
import csv
import json
import pathlib
import re
import sys
import urllib.error
import urllib.request

API = "https://api-web.nhle.com/v1"
TIMEOUT = 20

# The columns Keeper reads. `number` and `name` are the only required ones, but a
# code makes better filenames and a league groups the team menus.
COLUMNS = ["league", "team", "code", "number", "name", "position"]

POSITIONS = {"L": "Forward", "R": "Forward", "C": "Forward",
             "D": "Defence", "G": "Goalie"}


def get(url):
    request = urllib.request.Request(url, headers={"User-Agent": "keeper-rosters"})
    with urllib.request.urlopen(request, timeout=TIMEOUT) as response:
        return json.load(response)


def first_present(player, candidates, what):
    """The first of `candidates` that this player object actually has.

    The API's field names aren't documented anywhere official, so rather than
    assuming them this looks for each in turn and, failing all of them, says what
    the object *does* contain. A wrong guess then stops the script instead of
    quietly writing a CSV with a column of blanks.
    """
    for path in candidates:
        value = player
        for key in path.split("."):
            if not isinstance(value, dict) or key not in value:
                value = None
                break
            value = value[key]
        if value not in (None, ""):
            return value
    raise SystemExit(
        f"Couldn't find the {what} in a player from the API.\n"
        f"Tried: {', '.join(candidates)}\n"
        f"The player object has: {', '.join(sorted(player))}\n"
        "The API has probably changed shape. Send this message on and it's a "
        "one-line fix."
    )


def player_row(player, team_name, code, league):
    number = first_present(player, ["sweaterNumber", "jerseyNumber", "number"],
                           "jersey number")
    first = first_present(player, ["firstName.default", "firstName", "fullName"],
                          "first name")
    last = first_present(player, ["lastName.default", "lastName"], "last name")
    position = first_present(player, ["positionCode", "position"], "position")

    name = f"{first} {last}".strip() if last else str(first).strip()
    return {
        "league": league,
        "team": team_name,
        "code": code,
        "number": str(number).strip(),
        "name": name,
        "position": POSITIONS.get(str(position).strip().upper(), str(position).strip()),
    }


def roster(code, league):
    data = get(f"{API}/roster/{code}/current")
    groups = [k for k in ("forwards", "defensemen", "goalies") if k in data]
    if not groups:
        raise SystemExit(
            f"The roster for {code} didn't have the forwards/defensemen/goalies "
            f"lists this expects. It has: {', '.join(sorted(data))}"
        )
    players = [p for group in groups for p in data[group]]
    if not players:
        return []

    # The team's full name isn't in the roster response, so it comes from the
    # standings. Falling back to the code keeps a single-team run working even if
    # that call fails.
    name = TEAM_NAMES.get(code, code)
    return [player_row(p, name, code, league) for p in players]


TEAM_NAMES = {}


def league_teams():
    """Every team playing right now, from the standings.

    Discovered rather than written down: the league adds, moves and renames teams,
    and a hard-coded list of codes is the same staleness problem one level up.
    """
    data = get(f"{API}/standings/now")
    rows = data.get("standings") or []
    teams = {}
    for row in rows:
        code = first_present(row, ["teamAbbrev.default", "teamAbbrev"], "team code")
        name = first_present(row, ["teamName.default", "teamName", "teamCommonName.default"],
                             "team name")
        teams[str(code).strip().upper()] = str(name).strip()
    if not teams:
        raise SystemExit("The standings came back with no teams in them.")
    return teams


def slug(name):
    return "-".join(p for p in re.split(r"[^0-9a-z]+", name.lower()) if p)


def check(rows, code):
    """Keeper refuses a roster where two players share a number, because a player's
    id is team-and-number. Better to say so here than to have the import refuse it.
    """
    problems = []
    seen = {}
    for row in rows:
        number = row["number"]
        if not number:
            problems.append(f"{row['name']} has no number")
        elif number in seen:
            problems.append(f"#{number} is on both {seen[number]} and {row['name']}")
        else:
            seen[number] = row["name"]
    if problems:
        print(f"  ! {code}: {'; '.join(problems)}", file=sys.stderr)
        print("    Keeper won't import a team with a repeated or blank number — "
              "fix these in the CSV first.", file=sys.stderr)
    return not problems


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("teams", nargs="*", metavar="CODE",
                        help="three-letter team codes, e.g. WPG MTL")
    parser.add_argument("--all", action="store_true", help="every team in the league")
    parser.add_argument("-o", "--out", default=".", help="where to write (default: here)")
    parser.add_argument("--league", default="NHL", help="the league column (default: NHL)")
    parser.add_argument("--one-file", action="store_true",
                        help="one CSV holding every team rather than one each")
    args = parser.parse_args()

    if not args.teams and not args.all:
        parser.error("name some teams, or pass --all")

    global TEAM_NAMES
    try:
        TEAM_NAMES = league_teams()
    except (urllib.error.URLError, TimeoutError) as error:
        raise SystemExit(f"Couldn't reach the NHL API: {error}\n"
                         "Check you're online — this needs the internet.")

    codes = sorted(TEAM_NAMES) if args.all else [c.strip().upper() for c in args.teams]
    out = pathlib.Path(args.out).expanduser()
    out.mkdir(parents=True, exist_ok=True)

    everything = []
    failed = []
    for code in codes:
        try:
            rows = roster(code, args.league)
        except urllib.error.HTTPError as error:
            # A 404 here almost always means the code moved — a franchise relocating
            # or being renamed. Reported rather than fatal, so one bad code doesn't
            # cost you the other thirty-one.
            failed.append(f"{code} ({error.code})")
            continue
        except (urllib.error.URLError, TimeoutError) as error:
            failed.append(f"{code} ({error})")
            continue

        if not rows:
            failed.append(f"{code} (no players listed)")
            continue

        check(rows, code)
        everything.extend(rows)

        if not args.one_file:
            path = out / f"roster-{slug(TEAM_NAMES.get(code, code))}.csv"
            with path.open("w", newline="", encoding="utf-8") as handle:
                writer = csv.DictWriter(handle, fieldnames=COLUMNS)
                writer.writeheader()
                writer.writerows(rows)
            print(f"  {path}  ({len(rows)} players)")

    if args.one_file and everything:
        path = out / f"roster-{slug(args.league)}-all-teams.csv"
        with path.open("w", newline="", encoding="utf-8") as handle:
            writer = csv.DictWriter(handle, fieldnames=COLUMNS)
            writer.writeheader()
            writer.writerows(everything)
        print(f"  {path}  ({len(everything)} players across "
              f"{len({r['team'] for r in everything})} teams)")

    if failed:
        print(f"\nCouldn't fetch: {', '.join(failed)}", file=sys.stderr)
    if not everything:
        raise SystemExit("Nothing was written.")


if __name__ == "__main__":
    main()
