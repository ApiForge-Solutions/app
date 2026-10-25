#!/usr/bin/env bash
set -euo pipefail

FILE="${1:?fichier values manquant}"
BTAG="${2:?tag backend manquant}"
FTAG="${3:?tag frontend manquant}"

[[ "$BTAG" =~ ^backend-[0-9a-f]{8}$ ]]  || { echo "Tag backend invalide : $BTAG" >&2; exit 1; }
[[ "$FTAG" =~ ^frontend-[0-9a-f]{8}$ ]] || { echo "Tag frontend invalide : $FTAG" >&2; exit 1; }

for m in backend frontend; do
    n=$(grep -c "# ci:${m}-tag" "$FILE" || true)
    [ "$n" = "1" ] || { echo "$FILE : marqueur ci:${m}-tag trouvé $n fois (attendu : 1)" >&2; exit 1; }
done

sed -i -E \
    -e "s|^([[:space:]]*tag:[[:space:]]*).*(#[[:space:]]*ci:backend-tag)[[:space:]]*$|\1\"${BTAG}\"   \2|" \
    -e "s|^([[:space:]]*tag:[[:space:]]*).*(#[[:space:]]*ci:frontend-tag)[[:space:]]*$|\1\"${FTAG}\"   \2|" \
    "$FILE"

grep -q "\"${BTAG}\"" "$FILE" && grep -q "\"${FTAG}\"" "$FILE" || { echo "Écriture des tags échouée dans $FILE" >&2; exit 1; }
echo "$FILE : backend=${BTAG} frontend=${FTAG}"
