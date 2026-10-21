#!/usr/bin/env python3
"""
namecheap_dns.py — read and edit Namecheap DNS host records from the CLI.

No external dependencies (stdlib only: urllib + xml).

Credentials are read from environment variables:
    NAMECHEAP_API_USER   your Namecheap username (API user)
    NAMECHEAP_API_KEY    API key from Profile -> Tools -> API Access
    NAMECHEAP_USER_NAME  usually same as API_USER (defaults to it if unset)
    NAMECHEAP_CLIENT_IP  the public IP you whitelisted for the API
                         (if unset, the script auto-detects it)

The Namecheap setHosts API replaces *all* records at once, so any write
command here always: getHosts -> modify in memory -> setHosts the full set.
This avoids accidentally deleting records you didn't mention.

Examples:
    # list all records for a domain
    ./namecheap_dns.py get priyav.dev

    # add or update a single A record (upsert)
    ./namecheap_dns.py set priyav.dev --host app --type A --value 2.2.2.2 --ttl 1800

    # set the wildcard catch-all
    ./namecheap_dns.py set priyav.dev --host '*' --type A --value 1.1.1.1

    # remove a record
    ./namecheap_dns.py remove priyav.dev --host app --type A

    # preview a write without sending it
    ./namecheap_dns.py set priyav.dev --host app --type A --value 2.2.2.2 --dry-run
"""

import argparse
import os
import sys
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET

API_BASE = "https://api.namecheap.com/xml.response"
NS = "{http://api.namecheap.com/xml.response}"

# Fields Namecheap returns/accepts per host record.
RECORD_FIELDS = ("Name", "Type", "Address", "TTL", "MXPref")


class NamecheapError(Exception):
    pass


def get_credentials():
    api_user = os.environ.get("NAMECHEAP_API_USER")
    api_key = os.environ.get("NAMECHEAP_API_KEY")
    if not api_user or not api_key:
        raise NamecheapError(
            "Missing credentials. Set NAMECHEAP_API_USER and NAMECHEAP_API_KEY "
            "(and optionally NAMECHEAP_USER_NAME, NAMECHEAP_CLIENT_IP)."
        )
    user_name = os.environ.get("NAMECHEAP_USER_NAME", api_user)
    client_ip = os.environ.get("NAMECHEAP_CLIENT_IP") or detect_public_ip()
    return {
        "ApiUser": api_user,
        "ApiKey": api_key,
        "UserName": user_name,
        "ClientIp": client_ip,
    }


def detect_public_ip():
    try:
        with urllib.request.urlopen("https://api.ipify.org", timeout=10) as r:
            return r.read().decode().strip()
    except Exception as e:
        raise NamecheapError(
            f"Could not auto-detect public IP ({e}). "
            "Set NAMECHEAP_CLIENT_IP to your whitelisted IP."
        )


def split_domain(domain):
    """Split 'sub.example.com' style domain into SLD + TLD.

    Namecheap wants the registered domain as SLD (second-level) + TLD.
    For multi-label TLDs (co.uk) this naive split is wrong, but it's correct
    for the common single-label TLD case (.com, .dev, .io, ...).
    """
    parts = domain.strip(".").split(".")
    if len(parts) < 2:
        raise NamecheapError(f"Not a valid domain: {domain!r}")
    sld = parts[-2]
    tld = ".".join(parts[-1:])
    if len(parts) > 2:
        # e.g. example.co.uk -> sld=co tld=uk is wrong; warn the user.
        print(
            f"warning: {domain!r} has >2 labels; assuming SLD={sld} TLD={tld}. "
            "Pass the registered domain only (e.g. example.com).",
            file=sys.stderr,
        )
    return sld, tld


def api_call(command, extra_params):
    creds = get_credentials()
    params = {**creds, "Command": command, **extra_params}
    url = API_BASE + "?" + urllib.parse.urlencode(params)
    try:
        with urllib.request.urlopen(url, timeout=30) as r:
            raw = r.read()
    except Exception as e:
        raise NamecheapError(f"API request failed: {e}")

    root = ET.fromstring(raw)
    status = root.attrib.get("Status")
    if status != "OK":
        errs = root.find(f"{NS}Errors")
        msgs = [e.text for e in errs] if errs is not None else []
        raise NamecheapError("Namecheap API error: " + "; ".join(filter(None, msgs)))
    return root


def get_hosts(domain):
    """Return list of record dicts for the domain."""
    sld, tld = split_domain(domain)
    root = api_call(
        "namecheap.domains.dns.getHosts", {"SLD": sld, "TLD": tld}
    )
    result = root.find(f"{NS}CommandResponse/{NS}DomainDNSGetHostsResult")
    if result is None:
        return []
    records = []
    for host in result.findall(f"{NS}host"):
        a = host.attrib
        records.append(
            {
                "Name": a.get("Name", ""),
                "Type": a.get("Type", ""),
                "Address": a.get("Address", ""),
                "TTL": a.get("TTL", "1800"),
                "MXPref": a.get("MXPref", "10"),
            }
        )
    return records


def set_hosts(domain, records):
    """Replace ALL host records for the domain with `records`."""
    sld, tld = split_domain(domain)
    params = {"SLD": sld, "TLD": tld}
    # Namecheap expects HostName1, RecordType1, Address1, TTL1, MXPref1, ...
    for i, rec in enumerate(records, start=1):
        params[f"HostName{i}"] = rec["Name"]
        params[f"RecordType{i}"] = rec["Type"]
        params[f"Address{i}"] = rec["Address"]
        params[f"TTL{i}"] = rec.get("TTL", "1800")
        if rec["Type"] == "MX":
            params[f"MXPref{i}"] = rec.get("MXPref", "10")
    api_call("namecheap.domains.dns.setHosts", params)


def fmt_records(records):
    if not records:
        return "(no records)"
    width_name = max(len(r["Name"]) for r in records)
    width_type = max(len(r["Type"]) for r in records)
    lines = []
    for r in records:
        line = f"  {r['Name']:<{width_name}}  {r['Type']:<{width_type}}  {r['Address']}"
        if r["Type"] == "MX":
            line += f"  (pref {r['MXPref']})"
        line += f"  TTL={r['TTL']}"
        lines.append(line)
    return "\n".join(lines)


def cmd_get(args):
    records = get_hosts(args.domain)
    print(f"{args.domain}: {len(records)} record(s)")
    print(fmt_records(records))


def cmd_set(args):
    records = get_hosts(args.domain)
    new = {
        "Name": args.host,
        "Type": args.type,
        "Address": args.value,
        "TTL": str(args.ttl),
        "MXPref": str(args.mxpref),
    }
    # Upsert: match on (Name, Type). For MX you may want multiple, but the
    # common case is one record per (host, type), so replace in place.
    replaced = False
    for i, r in enumerate(records):
        if r["Name"] == new["Name"] and r["Type"] == new["Type"]:
            records[i] = new
            replaced = True
            break
    if not replaced:
        records.append(new)

    action = "update" if replaced else "add"
    print(f"Will {action} {args.host} {args.type} -> {args.value} (TTL {args.ttl})")
    print("\nResulting record set:")
    print(fmt_records(records))
    if args.dry_run:
        print("\n[dry-run] nothing sent.")
        return
    set_hosts(args.domain, records)
    print("\nDone.")


def cmd_remove(args):
    records = get_hosts(args.domain)
    before = len(records)
    kept = [
        r
        for r in records
        if not (
            r["Name"] == args.host
            and (args.type is None or r["Type"] == args.type)
        )
    ]
    removed = before - len(kept)
    if removed == 0:
        print(f"No record matched host={args.host!r} type={args.type!r}; nothing to do.")
        return
    print(f"Removing {removed} record(s) matching host={args.host!r} type={args.type!r}")
    print("\nResulting record set:")
    print(fmt_records(kept))
    if args.dry_run:
        print("\n[dry-run] nothing sent.")
        return
    set_hosts(args.domain, kept)
    print("\nDone.")


def build_parser():
    p = argparse.ArgumentParser(
        description="Read and edit Namecheap DNS records from the CLI.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )
    sub = p.add_subparsers(dest="command", required=True)

    g = sub.add_parser("get", help="list all records for a domain")
    g.add_argument("domain")
    g.set_defaults(func=cmd_get)

    s = sub.add_parser("set", help="add or update a single record (upsert)")
    s.add_argument("domain")
    s.add_argument("--host", required=True, help="hostname, e.g. @ or app or *")
    s.add_argument("--type", required=True, help="A, AAAA, CNAME, MX, TXT, ...")
    s.add_argument("--value", required=True, help="the address/target")
    s.add_argument("--ttl", type=int, default=1800)
    s.add_argument("--mxpref", type=int, default=10, help="MX priority (MX only)")
    s.add_argument("--dry-run", action="store_true", help="preview without sending")
    s.set_defaults(func=cmd_set)

    r = sub.add_parser("remove", help="remove records matching host (and type)")
    r.add_argument("domain")
    r.add_argument("--host", required=True)
    r.add_argument("--type", default=None, help="optional; if omitted, removes all types for host")
    r.add_argument("--dry-run", action="store_true", help="preview without sending")
    r.set_defaults(func=cmd_remove)

    return p


def main():
    parser = build_parser()
    args = parser.parse_args()
    try:
        args.func(args)
    except NamecheapError as e:
        print(f"error: {e}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
