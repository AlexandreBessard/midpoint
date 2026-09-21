#!/usr/bin/env python3
import argparse
import csv
import re
import sys
from collections import Counter

INTERIM_MARKERS = {"ZZZ", "ZZINT", "INT", "INTERIM", "INTERIMAIRE"}
PARTICLES = {"DE", "DU", "DES", "LA", "LE", "LES", "DA", "DI", "EL", "AL", "BEN", "VAN", "VON", "SAINT", "SAINTE"}


def split_marker(nompre):
    tokens = nompre.replace(":", " : ").split()
    marker = False
    while tokens and (tokens[0].upper() in INTERIM_MARKERS or tokens[0].upper() in ("CDD", "CDI", ":")):
        if tokens[0].upper() in INTERIM_MARKERS:
            marker = True
        tokens.pop(0)
    return marker, tokens


def clean_name(tokens):
    text = " ".join(tokens)
    text = re.sub(r"\([^)]*\)", " ", text)
    if ":" in text:
        text = text.rsplit(":", 1)[1]
    return text.split()


def split_identity(tokens):
    if len(tokens) == 2:
        return tokens[0], tokens[1]
    if len(tokens) == 3 and tokens[0].upper() in PARTICLES:
        return " ".join(tokens[:2]), tokens[2]
    return None


def main():
    p = argparse.ArgumentParser(description="Prepare HQZ.csv : garde les interimaires certains, ecarte machines et salaries CEGID.")
    p.add_argument("input")
    p.add_argument("output_interimaires")
    p.add_argument("output_a_verifier")
    p.add_argument("--input-encoding", default="utf-8-sig")
    args = p.parse_args()

    with open(args.input, newline="", encoding=args.input_encoding) as f:
        rows = list(csv.DictReader(f, delimiter=";", quotechar='"', skipinitialspace=True))

    stats = Counter()
    keep, review = [], []
    seen = set()

    for r in rows:
        usine = (r["usine"] or "").strip()
        matri = (r["matri"] or "").strip()
        nompre = (r["nompre"] or "").strip()
        seicegid = (r["seicegid"] or "").strip()
        horsect = (r["horsect"] or "").strip()

        if horsect.startswith("01"):
            stats["machines ecartees"] += 1
            continue
        if seicegid:
            stats["salaries CEGID ecartes"] += 1
            continue

        marker, tokens = split_marker(nompre)
        reason = None
        identity = None
        if not marker:
            reason = "pas de marqueur d'interim (INT/ZZZ/INTERIM)"
        else:
            tokens = clean_name(tokens)
            identity = split_identity(tokens)
            if identity is None:
                reason = "nom/prenom non separable"
            elif re.search(r"\d", " ".join(identity)):
                reason = "chiffres dans le nom"
        if reason:
            review.append({"usine": usine, "matri": matri, "nompre": nompre, "seicegid": seicegid, "horsect": horsect, "raison": reason})
            stats["lignes a verifier"] += 1
            continue

        key = f"{usine}-{matri}"
        if key in seen:
            stats["doublons usine+matri ecartes"] += 1
            continue
        seen.add(key)
        nom, prenom = identity
        keep.append({"id": key, "usine": usine, "matri": matri, "nom": nom.upper(), "prenom": prenom, "horsect": horsect})

    with open(args.output_interimaires, "w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=["id", "usine", "matri", "nom", "prenom", "horsect"], delimiter=";", quoting=csv.QUOTE_ALL, lineterminator="\r\n")
        w.writeheader()
        w.writerows(keep)

    with open(args.output_a_verifier, "w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=["usine", "matri", "nompre", "seicegid", "horsect", "raison"], delimiter=";", quoting=csv.QUOTE_ALL, lineterminator="\r\n")
        w.writeheader()
        w.writerows(review)

    print(f"Lignes lues                    : {len(rows)}", file=sys.stderr)
    for k in ("machines ecartees", "salaries CEGID ecartes", "lignes a verifier", "doublons usine+matri ecartes"):
        print(f"{k:31}: {stats[k]}", file=sys.stderr)
    print(f"Interimaires retenus           : {len(keep)}", file=sys.stderr)
    print("Raisons des lignes a verifier :", file=sys.stderr)
    for reason, n in Counter(r["raison"] for r in review).most_common():
        print(f"  {n:6} {reason}", file=sys.stderr)


if __name__ == "__main__":
    main()
