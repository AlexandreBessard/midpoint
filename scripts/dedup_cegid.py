#!/usr/bin/env python3
import argparse
import csv
import sys
from collections import defaultdict


def is_open(value):
    v = (value or "").strip()
    return v == "" or set(v) == {"0"}


def sort_key(row):
    opened = is_open(row["DATE_DEPART"])
    return (row["DATE_DEBUT"], opened, "" if opened else row["DATE_DEPART"])


def main():
    p = argparse.ArgumentParser(description="Une ligne par matricule (DATE_DEBUT la plus recente), latin1 -> UTF-8.")
    p.add_argument("input")
    p.add_argument("output")
    p.add_argument("--input-encoding", default="latin-1")
    args = p.parse_args()

    with open(args.input, newline="", encoding=args.input_encoding) as f:
        reader = csv.DictReader(f, delimiter=";")
        columns = reader.fieldnames
        rows = list(reader)

    required = ["MATRICULE", "PRENOM", "NOM", "DATE_DEBUT", "CODE_ENTITE"]
    incomplete = [r for r in rows if any(not (r[c] or "").strip() for c in required)]
    rows_ok = [r for r in rows if r not in incomplete]

    groups = defaultdict(list)
    for r in rows_ok:
        groups[r["MATRICULE"]].append(r)

    kept, ties, conflicts = [], [], []
    for matricule, group in groups.items():
        group.sort(key=sort_key, reverse=True)
        best = group[0]
        if len(group) > 1:
            if sort_key(group[0]) == sort_key(group[1]):
                ties.append(matricule)
            if not is_open(best["DATE_DEPART"]) and any(is_open(g["DATE_DEPART"]) for g in group):
                conflicts.append(matricule)
        kept.append(best)
    kept.sort(key=lambda r: r["MATRICULE"])

    with open(args.output, "w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=columns, delimiter=";", quoting=csv.QUOTE_ALL, lineterminator="\r\n")
        w.writeheader()
        w.writerows(kept)

    print(f"Lignes lues           : {len(rows)}", file=sys.stderr)
    print(f"Lignes rejetees (champ obligatoire vide : {', '.join(required)}) : {len(incomplete)}", file=sys.stderr)
    for r in incomplete[:20]:
        print("  -> " + ";".join(r[c] or "" for c in columns), file=sys.stderr)
    print(f"Matricules ecrits     : {len(kept)}", file=sys.stderr)
    print(f"Egalites (meme debut) : {len(ties)}", file=sys.stderr)
    print(f"Dernier contrat ferme mais autre contrat ouvert : {len(conflicts)}", file=sys.stderr)
    if conflicts:
        print("  -> " + ", ".join(conflicts), file=sys.stderr)


if __name__ == "__main__":
    main()
