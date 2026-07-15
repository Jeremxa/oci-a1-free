#!/bin/bash
# Ein einzelner Launch-Durchlauf über alle Availability Domains.
# Pro AD werden abwechselnd mehrere Shape-Größen versucht (siehe
# SHAPE_CONFIGS) – die kleinere ist evtl. eher verfügbar und lässt
# sich später aufstocken. GitHub Actions übernimmt das Scheduling.
#   - Exit 0, wenn Instanz erstellt ODER nur "keine Kapazität"  -> Lauf grün
#   - Exit 0 + Output "limit", wenn Free-Limit erreicht          -> Cron aus
#   - Exit 1 nur bei echten Konfig-/Auth-Fehlern                 -> Lauf rot
set -u

SHAPE="VM.Standard.A1.Flex"
DISPLAY_NAME="${DISPLAY_NAME:-a1-free}"

# Reihenfolge, in der pro AD versucht wird:  "OCPUs Memory_GB"
# Erste Zeile = Wunschgröße, danach kleinere Fallbacks.
SHAPE_CONFIGS=(
  "2 12"   # volle Free-Tier-Größe
  "1 6"    # halb so groß, evtl. eher frei – später aufstockbar
)

: "${COMPARTMENT_ID:?COMPARTMENT_ID fehlt}"
: "${SUBNET_ID:?SUBNET_ID fehlt}"
: "${SSH_PUBKEY:?SSH_PUBKEY fehlt}"

out() { [ -n "${GITHUB_OUTPUT:-}" ] && echo "$1=$2" >> "$GITHUB_OUTPUT"; }

echo ">> Availability Domains ..."
mapfile -t ADS < <(oci iam availability-domain list \
  --compartment-id "$COMPARTMENT_ID" --output json | jq -r '.data[].name')
echo "   ${ADS[*]}"

echo ">> Neuestes Ubuntu 24.04 (aarch64) Image ..."
IMAGE_ID=$(oci compute image list \
  --compartment-id "$COMPARTMENT_ID" \
  --operating-system "Canonical Ubuntu" \
  --operating-system-version "24.04" \
  --shape "$SHAPE" \
  --sort-by TIMECREATED --sort-order DESC \
  --output json | jq -r '.data[0].id')
echo "   $IMAGE_ID"

METADATA=$(jq -n --arg k "$SSH_PUBKEY" '{ssh_authorized_keys:$k}')
ERR=$(mktemp); OK=$(mktemp)

for AD in "${ADS[@]}"; do
  for CFG in "${SHAPE_CONFIGS[@]}"; do
    read -r C M <<<"$CFG"
    SHAPE_CFG=$(jq -n --argjson o "$C" --argjson m "$M" '{ocpus:$o, memoryInGBs:$m}')
    NAME="${DISPLAY_NAME}-${C}c"
    printf "Versuch in %s mit %s OCPU / %s GB ... " "$AD" "$C" "$M"

    if oci compute instance launch \
        --availability-domain "$AD" \
        --compartment-id "$COMPARTMENT_ID" \
        --shape "$SHAPE" \
        --shape-config "$SHAPE_CFG" \
        --image-id "$IMAGE_ID" \
        --subnet-id "$SUBNET_ID" \
        --assign-public-ip true \
        --display-name "$NAME" \
        --metadata "$METADATA" \
        >"$OK" 2>"$ERR"; then
      OCID=$(jq -r '.data.id' "$OK")
      echo "ERFOLG! (${C} OCPU / ${M} GB)  $OCID"
      out launched true
      out instance_ocid "$OCID"
      exit 0
    fi

    if grep -qi "Out of host capacity" "$ERR"; then
      echo "keine Kapazität"
    elif grep -qi -e "TooManyRequests" -e '"status": 429' "$ERR"; then
      echo "Rate-Limit"; sleep 10
    elif grep -qi -e "LimitExceeded" -e "quota" "$ERR"; then
      echo "Free-Limit erreicht – Instanz existiert vermutlich schon."
      out launched limit
      exit 0
    else
      echo "ANDERER FEHLER:"; cat "$ERR"
      exit 1
    fi
  done
done

echo "Alle ADs und Größen derzeit voll – nächster Lauf per Cron."
exit 0
