# App Store release notes

One folder per version, one file per App Store locale, holding the plain text that becomes
**What's New in This Version**:

```
0.7.0/en-US.txt
```

The `app-store` job in `.github/workflows/ios-release.yml` writes it onto the version it submits
(`tools/asc.py promote`). A missing file means the generic "Improvements and bug fixes." — it never
blocks a release. Per version on purpose: one file per locale would quietly ship the previous
release's notes with the next one. Apple refuses release notes on the **first** release, so they are
only written once a version is live. At most 4000 characters.

The version is picked automatically: once Apple approves a version, the next build goes out as the
next minor version. Add the folder for that version when you want real notes for it. TestFlight's
"What to test" is generated from the app's commit subjects instead.
