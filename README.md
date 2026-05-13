# RokidAPKs-iOS

Install APKs on Rokid AR glasses from an **iPhone** over Wi-Fi — no USB cable, no Android phone required.

---

## How it works

This project uses **Bonjour/mDNS + TCP** to replace the Bluetooth SPP control channel used by the original Android app.
iOS does not support Bluetooth Classic SPP for arbitrary connections, but it has full support for local-network TCP and Bonjour service advertising.

```
iPhone (iOS app)                       Rokid Glasses (Android companion)
─────────────────────────────────      ──────────────────────────────────────
1. Advertise _rokidapks._tcp           1. Discover _rokidapks._tcp via NSD
   over Bonjour                        2. TCP connect → receive offer JSON
2. Accept TCP connection               3. Pull APK over Wi-Fi TCP
3. Send offer JSON                     4. Verify MD5
   { hostIp, port, apkSize, md5 }      5. Launch PackageInstaller
4. Serve APK over TCP stream           6. Send result JSON back
5. Receive result JSON
```

**Requirements:**
- iPhone and glasses must be on the **same Wi-Fi network** (or iPhone hotspot + glasses connected to it)
- Glasses must have the companion app (`glasses-app/`) installed

---

## Project structure

```
ios-app/                     SwiftUI iPhone app (Xcode 15+, iOS 16+)
  RokidAPKsPhone.xcodeproj/
  RokidAPKsPhone/
    Sources/
      RokidAPKsPhoneApp.swift      @main entry
      ContentView.swift            SwiftUI UI
      TransferSession.swift        Transfer state machine (ObservableObject)
      BonjourControlServer.swift   Bonjour advertising + JSON control channel
      ApkStreamServer.swift        Raw TCP APK stream server
      NetworkUtils.swift           Local Wi-Fi IP resolution
      Models.swift                 Shared types and errors
    Info.plist
    Assets.xcassets/

glasses-app/                 Android companion app for the Rokid glasses
  src/main/java/com/rokidapks/glasses/
    MainActivity.kt               NSD discovery + transfer orchestration
    PackageInstallHelper.kt       PackageInstaller wrapper
    InstallResultReceiver.kt      Install result broadcast receiver
    PendingInstallStore.kt        SharedPreferences for pending installs
    tcp/
      IosDiscoveryClient.kt       NSD discovery → TCP socket
      TcpControlChannel.kt        JSON control framing over TCP
    spp/
      WifiApkSocketDownloader.kt  Raw TCP APK download (unchanged)
      SppPacketUtils.kt           MD5 helpers
      SppTransferConstants.kt     Shared constants
```

---

## Build

### iOS app

Open `ios-app/RokidAPKsPhone.xcodeproj` in **Xcode 15+** on a Mac.

1. Set your development team under **Signing & Capabilities**
2. Change the bundle ID from `com.rokidapks.ios` if needed
3. Build & run on a real iPhone (local-network permission requires a physical device)

> The app requests **Local Network** permission on first launch. Tap **Allow** when iOS asks.

### Glasses companion

```bash
./gradlew :glasses-app:assembleDebug
```

Install the resulting APK on the Rokid glasses:

```bash
adb install glasses-app/build/outputs/apk/debug/glasses-app-debug.apk
```

---

## Usage

1. Connect both iPhone and Rokid glasses to the **same Wi-Fi network**
2. Open **Rokid APKs** on the iPhone, tap **Select APK**, pick any `.apk` file
3. The iPhone will start advertising over Bonjour and wait
4. Open **Rokid APKs** on the glasses — it auto-discovers the iPhone and connects
5. The APK streams over Wi-Fi to the glasses
6. The install confirmation prompt appears on the glasses — confirm to install

---

## Protocol detail

### Control channel (TCP, Bonjour-advertised)

The iPhone opens a TCP server and advertises it as `_rokidapks._tcp` via Bonjour.
The glasses companion discovers it via Android NSD and connects.

All messages use the same framing as the original Kotlin `SppControlChannel`:

```
[4-byte big-endian Int32 length][UTF-8 JSON body]
```

**Offer** (iPhone → Glasses):
```json
{
  "type": "offer",
  "transportMode": "wifi_lan",
  "hostIp": "192.168.x.x",
  "port": 49152,
  "apkSize": 12345678,
  "md5": "abc123...",
  "fileName": "myapp.apk"
}
```

**Result** (Glasses → iPhone):
```json
{
  "type": "result",
  "success": true,
  "message": "APK received. Install prompt opening on glasses."
}
```

### APK data channel (TCP)

The iPhone opens a second TCP server on the port specified in the offer.
The glasses connect and receive the APK as a raw contiguous byte stream (no framing).
After receiving all bytes, the glasses verify the MD5 before launching `PackageInstaller`.

---

## Credits & acknowledgements

This project would not exist without the foundational work in these repositories:

- **[Anezium/Rokid-APKs](https://github.com/Anezium/Rokid-APKs)** — The SPP + Wi-Fi LAN transfer protocol,
  glasses companion app architecture, and PackageInstaller flow that this project is directly based on.
  The `WifiApkSocketDownloader.kt`, `SppPacketUtils.kt`, `PackageInstallHelper.kt`,
  `InstallResultReceiver.kt`, and the JSON control-channel wire format are adapted from this repo.

- **[Anezium/RokidBrew](https://github.com/Anezium/RokidBrew)** — The community app store for Rokid
  glasses that inspired this companion project.

- **[Miniontoby/RokidApkUploader](https://github.com/Miniontoby/RokidApkUploader)** — The original
  APK uploader for Rokid glasses that Rokid-APKs itself was based on.

Thank you to all contributors to those projects for mapping out the Rokid transfer protocols and
making this iOS port possible.

---

## License

GPL-3.0 — see [LICENSE](LICENSE), matching the upstream [Anezium/Rokid-APKs](https://github.com/Anezium/Rokid-APKs) license.
