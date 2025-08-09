#!/usr/bin/env bash
set -euo pipefail

ROOT="${1:-.}"
FILE="$ROOT/client/src/main.ts"

if [[ ! -f "$FILE" ]]; then
  echo "Missing $FILE" >&2
  exit 1
fi

tmp="$FILE.tmp.$$"

awk '
  BEGIN {
    in_hub=0;
    brace=0;
    saw_market=0;
  }
  {
    line=$0;

    # Detect start of hub button handler
    if (line ~ /document\.getElementById\('\''btn-hub'\''\)!\.addEventListener\('\''click'\'',/) {
      in_hub=1;
      brace=0;
      saw_market=0;
    }

    if (in_hub==1) {
      # Track if Market stop already present
      if (line ~ /mgr\.stop\('\''Market'\''\);/) {
        saw_market=1;
      }
    }

    print line;

    if (in_hub==1) {
      # When we see the Fishing stop and no Market stop yet, insert it just after
      if (line ~ /mgr\.stop\('\''Fishing'\''\);/ && saw_market==0) {
        print "  mgr.stop('\''Market'\'');"
        saw_market=1; # prevent duplicate insertions
      }

      # Update braces to detect end of handler block
      # Count { and } on the line (rough but works for our formatting)
      n_open = gsub(/\{/, "{", line);
      n_close = gsub(/\}/, "}", line);
      brace += (n_open - n_close);

      # If we left the block, reset flags
      if (brace <= 0 && line ~ /\}/) {
        in_hub=0;
        brace=0;
        saw_market=0;
      }
    }
  }
' "$FILE" > "$tmp"

# Only replace if something actually changed
if ! cmp -s "$FILE" "$tmp"; then
  mv "$tmp" "$FILE"
  echo "Patched: added mgr.stop('Market') to Hub button handler (if missing)."
else
  rm -f "$tmp"
  echo "No change needed: Hub button already stops Market."
fi
