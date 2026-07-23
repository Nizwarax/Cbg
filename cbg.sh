#!/usr/bin/env bash
# ==========================================================
#  💎 COINBUSTER GOD v3.1 — VPS / RAILWAY EDITION
#  SEMUA FILE: script + APK input + hasil = 1 FOLDER YANG SAMA
#  Penggunaan:
#     ./cbg.sh file.apk          # proses satu APK
#     ./cbg.sh --watch           # auto proses APK baru yang masuk
# ==========================================================
set +euo pipefail
shopt -s nullglob dotglob

# ==== KONFIG UTAMA (LO BOLEH UBAH) ====
COIN=999999999
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # FOLDER ROOT = TEMPAT SCRIPT INI BERADA
WORK="$HERE/.work"
KS=/root/.android/debug.keystore
UBER=/opt/uber.jar
NUKE=1              # 1 = MODE NUKLIR (potong semua proteksi+iklan+internet)
# =======================================

mkdir -p "$WORK"
R=$'\e[1;31m'; G=$'\e[1;32m'; Y=$'\e[1;33m'; B=$'\e[1;34m'; M=$'\e[1;35m'; C=$'\e[1;36m'; W=$'\e[0m'
log(){ echo -e "$1"; }
ok(){  log "${G}[✓] $*${W}"; }
inf(){ log "${C}[+] $*${W}"; }
wrn(){ log "${Y}[!] $*${W}"; }
err(){ log "${R}[✗] $*${W}"; }

banner(){
  clear
  echo -e "
${M}╔══════════════════════════════════════════════╗
${M}║   💎 COINBUSTER GOD v3.1  VPS/RAILWAY         ║
${M}║   ${W}ROOT = $HERE
${M}╚══════════════════════════════════════════════╝${W}"
}

# ---------- PROSES 1 APK ----------
proses_apk(){
  local APK="$1"
  [[ ! -f $APK ]] && { err "APK ga ada: $APK"; return 1; }
  local BASE=$(basename "$APK" .apk)
  local DEC="$WORK/$BASE" SRC="$WORK/${BASE}_src"
  rm -rf "$DEC" "$SRC"; mkdir -p "$DEC" "$SRC"

  banner
  inf "APK     : $APK"
  inf "FOLDER  : $HERE"

  # Backup APK asli ke FOLDER ROOT
  cp -f "$APK" "$HERE/${BASE}_ORIGINAL.apk"
  ok "Backup asli → $HERE/${BASE}_ORIGINAL.apk"

  # --- TIER 1: DEKOMPILASI ---
  inf "TIER 1 — Bongkar + JADX deobf..."
  apktool d -f -r --no-src "$APK" -o "$DEC" >/dev/null 2>&1 || apktool d -f "$APK" -o "$DEC"
  PKG=$(grep -m1 -oP 'package="\K[^"]+' "$DEC/AndroidManifest.xml" 2>/dev/null || echo unknown)
  ok "Package = $PKG"

  jadx --deobf --deobf-min 3 --deobf-max 10 -j 4 -r -s --no-imports -d "$SRC" "$APK" >/dev/null 2>&1 \
    && ok "JADX deobf OK" || wrn "JADX parsial"

  UNITY=0
  find "$DEC" -name "libil2cpp.so" 2>/dev/null | grep -q . && UNITY=1 && ok "UNITY IL2CPP terdeteksi"

  # --- TIER 2: SCAN TARGET ---
  inf "TIER 2 — Fuzzy scan method..."
  MAP="$WORK/patch.map"; > "$MAP"
  KEYS='getCoin getBalance getGold getGem getDiamond getPoint getSaldo getMoney
        hasEnoughCoin isEnough canAfford canBuy isPremium isPro isVip isSubscribed
        isPurchased isPaid isUnlocked checkLicense verifyPurchase purchase buy
        deductCoin useCoin spendCoin subBalance addCoin rewardCoin giveCoin
        showRewardedAd loadRewardedAd showAd onRewarded onAdRewarded
        isRooted isDebuggerConnected checkSignature verifySignatures getSignatures
        checkTamper isTampered okhttp3 CertificatePinner TrustManager checkPlayIntegrity'

  while IFS= read -r F; do
    [[ ! -s $F ]] && continue
    CLS=$(grep -m1 -oP '^package \K[^;]+' "$F" 2>/dev/null).$(basename "$F" .java); CLS=${CLS#.}
    for K in $KEYS; do
      grep -nE "(public|private|protected|static|native).* $K\s*\(" "$F" 2>/dev/null | while IFS=: read LN SIG; do
        MN=$(echo "$SIG" | grep -oP '\w+\s*\(' | head -1 | tr -d ' (')
        RET=$(echo "$SIG" | grep -oP '(long|int|boolean|String|double|float)')
        echo "$CLS|${MN:-$K}|${RET:-void}|$K" >> "$MAP"
      done
    done
  done < <(find "$SRC" -name "*.java" 2>/dev/null)
  sort -u "$MAP" -o "$MAP"
  TOTAL=$(wc -l < "$MAP")
  ok "Target ditemukan: $TOTAL"

  # --- TIER 3: PATCH SMALI ---
  inf "TIER 3 — Patch SMALI + NUKLIR..."
  PATCHED=0
  patch_one(){
    local F="$1" M="$2" MODE="$3" BODY="" IN=1 CHANGED=0 TMP=$(mktemp)
    while IFS= read -r LINE; do
      OUTL="$LINE"
      if [[ $LINE =~ ^\.method.*[[:space:]]${M}\( ]]; then
        case $MODE in
          COIN)  BODY="    const-wide v0, ${COIN}\n    return-wide v0\n" ;;
          TRUE)  BODY="    const/4 v0, 0x1\n    return v0\n" ;;
          FALSE) BODY="    const/4 v0, 0x0\n    return v0\n" ;;
          NOOP)  BODY="    return-void\n" ;;
          NOOPT) BODY="    const/4 v0, 0x1\n    return v0\n" ;;
        esac
        while read -r L2; do [[ $L2 =~ ^\.end\ method ]] && { OUTL="${BODY}.end method"; IN=0; CHANGED=1; break; }; done
      fi
      [[ $IN -eq 1 ]] && echo "$OUTL"; IN=1
    done < "$F" > "$TMP"
    [[ $CHANGED -eq 1 ]] && { mv "$TMP" "$F"; return 0; } || { rm -f "$TMP"; return 1; }
  }

  for SM in "$DEC"/smali*; do
    [[ -d $SM ]] || continue
    while IFS='|' read -r CLS MN RET TAG; do
      [[ -z $CLS ]] && continue
      SP="$SM/${CLS//.//}.smali"; [[ ! -f $SP ]] && continue
      case "$TAG" in
        getCoin|getBalance|getGold|getGem|getDiamond|getPoint|getSaldo|getMoney|addCoin|rewardCoin|giveCoin) MODE=COIN ;;
        hasEnoughCoin|isEnough|canAfford|canBuy|isPremium|isPro|isVip|isSubscribed|isPurchased|isPaid|isUnlocked|checkLicense|verifyPurchase|purchase|buy|showRewardedAd|onRewarded) MODE=TRUE ;;
        deductCoin|useCoin|spendCoin|subBalance) MODE=NOOPT ;;
        isRooted|isDebuggerConnected|checkTamper|isTampered|checkPlayIntegrity) MODE=FALSE ;;
        checkSignature|verifySignatures|getSignatures|CertificatePinner|TrustManager) MODE=NOOP ;;
        *) MODE=TRUE ;;
      esac
      patch_one "$SP" "$MN" "$MODE" && PATCHED=$((PATCHED+1))
    done < "$MAP"
  done

  if [[ $NUKE -eq 1 ]]; then
    MAN="$DEC/AndroidManifest.xml"
    sed -i -E '/(INTERNET|ACCESS_NETWORK_STATE|ACCESS_WIFI_STATE)/d' "$MAN"
    for AD in com.google.android.gms.ads com.unity3d.ads com.applovin com.ironsource com.facebook.ads com.vungle com.pangle; do
      sed -i "/${AD//./\\.}/Id" "$MAN" 2>/dev/null || true
    done
    for F in $(grep -rlE "getSignature|checkSign|isDebugg|isRooted|checkTamper|PlayIntegrity|CertificatePinner" "$DEC"/smali* 2>/dev/null); do
      sed -i -E 's/(invoke-virtual|invoke-static).*(getSignature|checkSign|isDebugg|isRooted|checkTamper|PlayIntegrity|CertificatePinner).*/    const\/4 v0, 0x0/g' "$F" 2>/dev/null || true
    done
    ok "NUKLEAR: proteksi + iklan + internet = DIPOTONG"
  fi
  ok "Smali terpatch: $PATCHED"

  # --- TIER 4: UNITY IL2CPP ---
  if [[ $UNITY -eq 1 ]]; then
    inf "TIER 4 — Unity IL2CPP native hex patch..."
    find "$DEC" -name "libil2cpp.so" | while read -r SO; do
      python3 - "$SO" <<'PY'
import sys,re
p=sys.argv[1]
with open(p,'rb') as f: d=bytearray(f.read())
for m in list(re.finditer(rb'\x00\x00\x80\x52', d)):
    d[m.start():m.start()+4]=b'\x00\x40\xbe\x52'
with open(p,'wb') as f: f.write(d)
PY
    done
    ok "IL2CPP OK"
  fi

  # --- TIER 5: BUILD + UBER SIGN v1+v2+v3 ---
  inf "TIER 5 — Rakit + Sign v1+v2+v3..."
  UNSIG="$WORK/_unsigned.apk"
  apktool b --use-aapt2 "$DEC" -o "$UNSIG" >/dev/null 2>&1 || apktool b "$DEC" -o "$UNSIG"
  MOD="$HERE/${BASE}_MOD.apk"
  java -jar "$UBER" -a "$UNSIG" -o "$HERE" --allowResign --overwrite >/dev/null 2>&1
  mv -f "$HERE/${BASE%.*}_unsigned-aligned-debugSigned.apk" "$MOD" 2>/dev/null
  [[ ! -s $MOD ]] && { zipalign -f -p 4 "$UNSIG" "$WORK/_al.apk"; apksigner sign --ks "$KS" --ks-pass pass:android --key-pass pass:android --out "$MOD" "$WORK/_al.apk" 2>/dev/null; }
  [[ -s $MOD ]] && ok "APK MOD JADI → $MOD" || err "Build gagal"

  # --- TIER 6: FRIDA CADANGAN KE FOLDER ROOT ---
  inf "TIER 6 — Generate Frida GOD script..."
  FJS="$HERE/${BASE}_GOD.js"
  OBC="$HERE/objection_commands.txt"
  {
    echo "// COINBUSTER GOD — $PKG"
    echo "// Run: frida -U -f $PKG -l ${BASE}_GOD.js --no-pause"
    echo "Java.perform(function(){const C=$COIN;"
    while IFS='|' read -r CLS MN RET TAG; do
      [[ -z $CLS ]] && continue
      case "$TAG" in
        getCoin|getBalance|getGold|getGem|getDiamond|getPoint|getSaldo|getMoney|addCoin|rewardCoin|giveCoin)
          echo "try{Java.use('$CLS').$MN.implementation=()=>C;}catch(e){}" ;;
        hasEnoughCoin|isEnough|canAfford|canBuy|isPremium|isPro|isVip|isSubscribed|isPurchased|isPaid|isUnlocked|checkLicense|verifyPurchase|purchase|buy|showRewardedAd|onRewarded)
          echo "try{Java.use('$CLS').$MN.implementation=()=>true;}catch(e){}" ;;
        deductCoin|useCoin|spendCoin|subBalance)
          echo "try{Java.use('$CLS').$MN.implementation=()=>true;}catch(e){}" ;;
        isRooted|isDebuggerConnected|checkTamper|isTampered|checkPlayIntegrity)
          echo "try{Java.use('$CLS').$MN.implementation=()=>false;}catch(e){}" ;;
        checkSignature|verifySignatures|getSignatures|CertificatePinner)
          echo "try{Java.use('$CLS').$MN.implementation=()=>null;}catch(e){}" ;;
      esac
    done < "$MAP"
    cat <<'EOF'
  Java.enumerateLoadedClasses({onMatch(c){
    if(!/Wallet|Coin|Balance|Gold|Premium|Vip|Purchase|AdManager|Reward|IAP|Billing|License|Integrity|Tamper|Root|Debug|Sign/i.test(c)) return;
    try{const K=Java.use(c);const ms=K.class.getDeclaredMethods();
      ms.forEach(m=>{const n=m.getName();
        try{
             if(/getCoin|getBalance|getGold|getGem|getDiamond|getPoint|getSaldo/i.test(n)) K[n].implementation=()=>C;
        else if(/hasEnough|isEnough|canAfford|canBuy|isPremium|isPro|isVip|isSubscribed|isPurchased|isPaid|isUnlocked|checkLicense|verifyPurchase|purchase|buy|showReward|onReward/i.test(n)) K[n].implementation=()=>true;
        else if(/deduct|useCoin|spend|subBalance/i.test(n)) K[n].implementation=()=>true;
        else if(/isRooted|isDebug|checkTamper|isTamper|PlayIntegrity/i.test(n)) K[n].implementation=()=>false;
        else if(/checkSign|verifySign|getSignature|CertificatePinner/i.test(n)) K[n].implementation=()=>null;
        }catch(_){}
      });
    }catch(_){}
  },onComplete(){}});
  try{const TM=Java.registerClass({name:'cbg.TM',implements:[Java.use('javax.net.ssl.X509TrustManager')],methods:{checkClientTrusted(){},checkServerTrusted(){},getAcceptedIssuers(){return [];}}});
    Java.use('javax.net.ssl.SSLContext').getInstance.overload('java.lang.String').implementation=function(p){const c=this.getInstance(p);c.init(null,[TM.$new()],null);return c;};
  }catch(_){}
  console.log("\n💎 COINBUSTER GOD AKTIF — COIN =",C);
});
EOF
  } > "$FJS"
  echo "objection -g $PKG explore -s 'android sslpinning disable ; android root disable'" > "$OBC"
  ok "Frida → $FJS"

  # Laporan
  cat > "$HERE/report.html" <<EOF
<h1>COINBUSTER GOD — Report</h1>
<p><b>APK:</b> $BASE<br><b>Package:</b> $PKG<br><b>Target patched:</b> $TOTAL<br><b>Smali patched:</b> $PATCHED<br><b>Unity IL2CPP:</b> $UNITY<br><b>Nuclear mode:</b> $NUKE</p>
EOF

  echo -e "\n${G}✅ SELESAI${W} — semua hasil di: $HERE"
  ls -la "$HERE"/*.apk "$HERE"/*.js 2>/dev/null | awk '{print "   "$NF}'
  rm -rf "$DEC" "$SRC" "$WORK"/*.apk 2>/dev/null
}

# ---------- MODE WATCH: TARO APK → OTOMATIS PROSES ----------
mode_watch(){
  command -v inotifywait >/dev/null || apt install -y inotify-tools >/dev/null 2>&1
  inf "🔭 MODE WATCH AKTIF — taro APK apapun di $HERE, langsung diproses..."
  inotifywait -m -e close_write --format '%f' "$HERE" | while read -r F; do
    [[ $F == *.apk && $F != *_MOD.apk && $F != *_ORIGINAL.apk ]] || continue
    sleep 1
    proses_apk "$HERE/$F"
  done
}

# ---------- MAIN ----------
case "${1:-}" in
  --watch|-w) mode_watch ;;
  -h|--help)  echo "Penggunaan:\n  $0 file.apk      # proses 1 APK\n  $0 --watch       # auto proses APK baru"; exit 0 ;;
  *)           [[ -z ${1:-} ]] && { echo "Pake: $0 nama.apk  atau  $0 --watch"; exit 1; }
               for A in "$@"; do proses_apk "$A"; done ;;
esac
