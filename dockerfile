FROM debian:bookworm-slim
ENV DEBIAN_FRONTEND=noninteractive
WORKDIR /data/cbg

# Install semua alat + JADX + Uber APK Signer
RUN apt update -y && apt install -y --no-install-recommends \
    wget curl unzip ca-certificates openjdk-17-jdk-headless python3 python3-pip \
    aapt apksigner zipalign apktool build-essential git procps inotify-tools \
    && rm -rf /var/lib/apt/lists/*

# JADX terbaru (bukan repo apt yang jadul)
RUN JADX=$(curl -sL https://api.github.com/repos/skylot/jadx/releases/latest | grep -oP 'browser_download_url.*jadx-\d[\d.]+.zip' | head -1 | cut -d'"' -f4) \
    && wget -q "$JADX" -O /tmp/jadx.zip \
    && unzip -q /tmp/jadx.zip -d /opt/jadx \
    && ln -sf /opt/jadx/bin/jadx /usr/local/bin/jadx \
    && rm /tmp/jadx.zip

# Uber APK Signer v1+v2+v3
RUN wget -q https://github.com/patrickfav/uber-apk-signer/releases/download/v1.3.0/uber-apk-signer-1.3.0.jar -O /opt/uber.jar

# Debug keystore
RUN mkdir -p /root/.android && keytool -genkey -v -keystore /root/.android/debug.keystore \
    -storepass android -alias androiddebugkey -keypass android -keyalg RSA -keysize 2048 \
    -validity 10000 -dname "CN=Android Debug,O=Android,C=US" >/dev/null 2>&1

# Script utama
COPY cbg.sh /data/cbg/cbg.sh
RUN chmod +x /data/cbg/cbg.sh && ln -sf /data/cbg/cbg.sh /usr/local/bin/cbg

# Persistent volume Railway
VOLUME /data

EXPOSE 7681
# Default: buka web terminal ttyd biar LO bisa kontrol lewat browser Railway
CMD ["sh","-c","apt install -y ttyd >/dev/null 2>&1; ttyd -p 7681 -W -c lo:gantipassword bash"]
