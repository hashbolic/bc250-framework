# BC250 Framework

Public runtime framework for production AMD BC-250 consoles running the BC250 Bazzite image.

Production commands:

- `bc setup` — configure the console.
- `bc status` — verify the setup.
- `bc cu-test` — interactive CU/WGP qualification with FurMark.
- `bc game` — apply tested game-specific profiles such as the CS2 affinity baseline.
- `bc reset` — return framework-managed state to clean post-install provisioning.
- `bc update` — update from the latest signed release.
- `bc rollback` — return to the previous framework release.
- `bc version` — show the active framework version.

Numbered engineering commands are intentionally not shipped in production.

## Release model

Tagged releases publish:

- `bc250-framework.tar.zst`
- `manifest.json`
- `bc250-framework.cosign.bundle`

The archive is signed keylessly by GitHub Actions with Sigstore/Cosign. Production consoles verify the workflow identity before switching the atomic `current` symlink.
