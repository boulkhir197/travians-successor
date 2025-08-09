#!/usr/bin/env bash
set -euo pipefail
FILE="client/src/main.ts"
test -f "$FILE" || { echo "Missing $FILE" >&2; exit 1; }

# If a btn-hub handler exists, make sure it stops 'Market' as well.
if grep -q "btn-hub" "$FILE"; then
  # Insert mgr.stop('Market'); if missing in the hub button handler
  perl -0777 -pe "
    s@(document\.getElementById\('btn-hub'\)!\.addEventListener\('click', \(\) => \{\s*?\n\s*?const mgr = game\.scene;\s*?\n\s*?mgr\.stop\('Fishing'\);\s*?\n)@${1}  mgr.stop('Market');\n@
  " -i.bak "$FILE" || true
  rm -f "$FILE.bak"
  echo " + Ensured btn-hub also stops 'Market'"
else
  # If no handler was found (edge case), wire one in a safe way using window.game
  cat >> "$FILE" <<'TS'

/* FIX_HUB_BUTTON */
(() => {
  const run = () => {
    // @ts-ignore
    const g = (window as any).game;
    if (!g || !g.scene) return false;
    const btn = document.getElementById('btn-hub');
    if (!btn) return false;
    btn.addEventListener('click', () => {
      const mgr = g.scene;
      mgr.stop('Fishing'); mgr.stop('Market');
      if (mgr.isActive('Hub')) mgr.bringToTop('Hub'); else mgr.start('Hub');
    });
    return true;
  };
  if (!run()) {
    const iv = setInterval(() => { if (run()) clearInterval(iv); }, 200);
    setTimeout(() => clearInterval(iv), 8000);
  }
})();
TS
  echo " + Added FIX_HUB_BUTTON wiring"
fi

echo "Hub button fix applied."
