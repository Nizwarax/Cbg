FROM debian:bookworm-slim
ENV DEBIAN_FRONTEND=noninteractive
ENV HOME=/root
WORKDIR /data/cbg

# --- SYSTEM DEPS ---
RUN apt update -y && apt install -y --no-install-recommends \
    wget curl unzip ca-certificates \
    openjdk-17-jdk-headless python3 python3-pip \
    aapt apksigner zipalign build-essential git procps \
    && rm -rf /var/lib/apt/lists/*

# --- APKTOOL TERBARU (repo apt jadul!) ---
RUN wget -q https://raw.githubusercontent.com/iBotPeaches/Apktool/master/scripts/linux/apktool -O /usr/local/bin/apktool \
    && wget -q https://bitbucket.org/iBotPeaches/apktool/downloads/apktool_2.9.3.jar -O /usr/local/bin/apktool.jar \
    && chmod +x /usr/local/bin/apktool /usr/local/bin/apktool.jar

# --- JADX TERBARU ---
RUN JADX_URL=$(curl -sL https://api.github.com/repos/skylot/jadx/releases/latest | grep -oP '"browser_download_url":\s*"\K[^"]+jadx-\d[^"]+\.zip' | head -1) \
    && wget -q --tries=5 --retry-connrefused "$JADX_URL" -O /tmp/jadx.zip \
    && unzip -q /tmp/jadx.zip -d /opt/jadx \
    && ln -sf /opt/jadx/bin/jadx /usr/local/bin/jadx \
    && rm -f /tmp/jadx.zip

# --- UBER APK SIGNER v1+v2+v3 ---
RUN wget -q --tries=5 --retry-connrefused \
    https://github.com/patrickfav/uber-apk-signer/releases/download/v1.3.0/uber-apk-signer-1.3.0.jar \
    -O /opt/uber.jar

# --- DEBUG KEYSTORE ---
RUN mkdir -p /root/.android \
    && keytool -genkey -v -keystore /root/.android/debug.keystore \
       -storepass android -alias androiddebugkey -keypass android \
       -keyalg RSA -keysize 2048 -validity 10000 \
       -dname "CN=Android Debug,O=Android,C=US" >/dev/null 2>&1

# --- TTYD (WEB TERMINAL RAILWAY) ---
RUN TTYD_URL=$(curl -sL https://api.github.com/repos/tsl0922/ttyd/releases/latest | grep -oP '"browser_download_url":\s*"\K[^"]+x86_64' | head -1) \
    && wget -q --tries=5 "$TTYD_URL" -O /usr/local/bin/ttyd \
    && chmod +x /usr/local/bin/ttyd

# --- COPY SCRIPT UTAMA ---
COPY cbg.sh /data/cbg/cbg.sh
RUN chmod +x /data/cbg/cbg.sh \
    && ln -sf /data/cbg/cbg.sh /usr/local/bin/cbg

VOLUME ["/data"]
EXPOSE 7681

# --- START WEB TERMINAL ---
CMD ["ttyd","-p","7681","-W","-c","lo:sayangenicbg46","bash"]
