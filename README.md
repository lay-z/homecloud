# priyav.dev DNS tooling

`namecheap_dns.py` — read and edit Namecheap DNS records from the CLI. No
external dependencies (Python 3 stdlib only).

## One-time setup

1. **Enable the API** in Namecheap: Profile → Tools → Namecheap API Access →
   toggle on. (Account gate: 20+ domains, OR $50+ balance, OR $50+ spent.)
2. **Whitelist your public IP** on the same page.
3. Copy creds template and fill it in:
   ```bash
   cp .namecheap.env.example .namecheap.env
   $EDITOR .namecheap.env
   source .namecheap.env
   ```

## Usage

```bash
# list all records
./namecheap_dns.py get priyav.dev

# add/update one record (upsert — matches on host+type)
./namecheap_dns.py set priyav.dev --host app --type A --value 2.2.2.2 --ttl 1800

# wildcard catch-all -> server A
./namecheap_dns.py set priyav.dev --host '*' --type A --value 1.1.1.1

# specific override -> server B (wins over wildcard)
./namecheap_dns.py set priyav.dev --host app --type A --value 2.2.2.2

# remove a record
./namecheap_dns.py remove priyav.dev --host app --type A

# preview any write without sending
./namecheap_dns.py set priyav.dev --host app --type A --value 2.2.2.2 --dry-run
```

## Two-server routing pattern

Both servers have public IPs. Split at the DNS level — a more-specific record
always beats the wildcard:

```bash
./namecheap_dns.py set priyav.dev --host '*'   --type A --value <server-A-ip>   # default
./namecheap_dns.py set priyav.dev --host app   --type A --value <server-B-ip>   # override
./namecheap_dns.py set priyav.dev --host api   --type A --value <server-B-ip>   # override
```

Adding a future site on server B = one `set` command. Server A = nothing
(wildcard catches it). Each server terminates its own HTTPS.

## Safety note

Namecheap's `setHosts` API replaces **all** records in one call. Every write
command here does `getHosts → modify in memory → setHosts the full set`, so it
never clobbers records you didn't mention. Use `--dry-run` to see the full
resulting record set before committing.
