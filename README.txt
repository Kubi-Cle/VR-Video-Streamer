VR Video Streamer, Version 1.2.0
Stream your desktop, application windows, local video files and online videos to VR video players.
Needs Windows 10 (version 2004 or newer) or Windows 11, 64-bit.

START
1. Extract the zip (right-click, Extract All). It won't run from inside the zip.
2. Open "VR Video Streamer.exe". Keep it beside the "app" folder.
3. If Windows says "Windows protected your PC", choose More info, then Run anyway. It appears because the
   program isn't digitally signed.
4. Press Download when asked about FFmpeg, the video tool it needs (about 110 MB, only once).
5. If Windows Firewall asks about mediamtx.exe, allow it on Private networks.

WATCH IN VR
1. Choose what to stream and press Start streaming. The public link is copied for you.
2. Paste it into a video player in your VR game.
3. To stop hearing a program twice, turn on its "Mute on PC" switch in the sound list. It goes silent on your PC until you
   press Stop, and viewers still hear it at its normal volume.

You can change the Sound ticks while streaming. Videos with chapters get a Chapters button to jump between them.
Each ticked sound has its own volume slider for viewers. If viewers hear things before they see them, move
"Sound delay" to the right. Both work while streaming.

Other links:
- Short link: the same stream with a shorter ending, easier to type in a headset.
- Remote control: a web page for pausing, skipping, jumping and adding YouTube links from a phone. Only give it to
  people you trust. It stops working when you press Stop.
- QR: shows a link as a code a phone camera can open.
If the public link's service drops, it reconnects by itself without stopping the stream. A free link's address
changes when that happens, and the window shows the new one.

Subtitles menu: "Translate these" puts the subtitles showing into your language, using Google Translate (it sends the
subtitle text to Google). The window remembers your choices for next time, and tells you when there's a newer version.

Anyone with the link can watch until you press Stop, and it changes each time you start. Only share it with people
you mean to, and only stream what you have the right to share.

PRIVACY
Viewers can see everything on the screen or window you stream, including passwords and notifications. Public links
pass through a third-party service (Cloudflare, localhost.run or Pinggy), and Pinggy links show your IP address.

IF SOMETHING GOES WRONG
- Nothing opens: Windows sometimes checks a new program first. Wait a few seconds and open it again.
- The FFmpeg download seems stuck: it's usually quick but can take several minutes. Give it time.
- It stutters: pick a lower Quality, or press Test my upload.
- The public link fails: pick another service beside the public link option. Starting and stopping too often can get you
  rate limited, so wait a while before trying again.
- Asking for help: press Copy problem report and paste it into a new issue at
  https://github.com/Kubi-Cle/VR-Video-Streamer/issues. It leaves out your name and links, but issues are public, so
  read it before you post.

OTHER DOWNLOADS
AI subtitles ask before downloading what they need (up to about 700 MB). Keys and settings stay in your Windows
profile, not this folder.

UNINSTALL
Delete this folder, and %LOCALAPPDATA%\VRVideoStreamer to remove your settings too.

LICENCE
Free for noncommercial use under the PolyForm Noncommercial License 1.0.0, in the LICENSE file. Included tools keep
their own licences, listed in THIRD-PARTY-NOTICES.txt.
