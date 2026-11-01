#!/usr/bin/env python3
"""Appelle l'API HRUX de CEGID (dossier.contrat.exporter.csv) et ecrit la reponse
dans import/CEGID/ sous un nom horodate (CEGID_AAAAMMJJ_HHMMSS.csv)."""
import argparse
import datetime
import os
import sys
import urllib.error
import urllib.parse
import urllib.request

URL = os.environ.get("CEGID_URL", "https://anett-hru.cegid.com/hru/hrux_c47e.jsp")
WEB_SERVICE_APPLICATION = "STANDARD"
WEB_SERVICE = "dossier.contrat.exporter.csv"
MDTRT = "ALL"


def fetch(token_id, token_value, cdvue):
    params = {
        "webServiceApplication": WEB_SERVICE_APPLICATION,
        "webService": WEB_SERVICE,
        "tokenId": token_id,
        "tokenValue": token_value,
        "cdvue": cdvue,
        "mdtrt": MDTRT,
    }
    data = urllib.parse.urlencode(params).encode("ascii")
    request = urllib.request.Request(URL, data=data, method="POST")
    request.add_header("Content-Type", "application/x-www-form-urlencoded")
    with urllib.request.urlopen(request, timeout=60) as response:
        return response.getcode(), response.read()


def main():
    parser = argparse.ArgumentParser(description="Recupere l'export CEGID via l'API HRUX et l'ecrit dans import/CEGID/.")
    parser.add_argument("--output-dir", default=None, help="Dossier de destination (defaut : import/CEGID, le dossier parent de ce script)")
    args = parser.parse_args()

    token_id = os.environ.get("CEGID_TOKEN_ID", "MIDPOINT")
    token_value = os.environ.get("CEGID_TOKEN_VALUE")
    cdvue = os.environ.get("CEGID_CDVUE", "MIDPOINT")

    if not token_value:
        print("Erreur : la variable d'environnement CEGID_TOKEN_VALUE n'est pas definie.", file=sys.stderr)
        sys.exit(1)

    output_dir = args.output_dir or os.path.join(os.path.dirname(os.path.abspath(__file__)), os.pardir)
    output_dir = os.path.abspath(output_dir)
    os.makedirs(output_dir, exist_ok=True)

    timestamp = datetime.datetime.now().strftime("%Y%m%d_%H%M%S")
    output_path = os.path.join(output_dir, f"CEGID_{timestamp}.csv")

    try:
        status, body = fetch(token_id, token_value, cdvue)
    except urllib.error.URLError as exc:
        print(f"Erreur reseau lors de l'appel a {URL} : {exc}", file=sys.stderr)
        sys.exit(1)

    if status != 200:
        print(f"Erreur : reponse HTTP {status}", file=sys.stderr)
        sys.exit(1)

    if not body.strip():
        print("Erreur : reponse vide recue de CEGID.", file=sys.stderr)
        sys.exit(1)

    with open(output_path, "wb") as f:
        f.write(body)

    print(f"Export ecrit : {output_path} ({len(body)} octets)")


if __name__ == "__main__":
    main()
