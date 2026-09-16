# Legacy

This folder keeps files that are no longer used by the current DuoMo build.
They remain here for reference and are not copied into the application bundle.

## IconSources

- `4EF0FC53-DFD1-497F-9C14-5E9315E2C148.png`: original supplied icon artwork. The active derived assets are `Resources/AppIcon.png` and `Resources/AppIcon.icns`.
- `AppIcon.svg`: older SVG icon export that is not referenced by the current build.
- `AppIcon.icon`: older Icon Composer project that is not referenced by the current build.
- `Untitled.icon`: duplicate older Icon Composer project formerly copied into the app bundle but never used by `Info.plist`.

## Builds

`Builds/` contains archived local release outputs and is intentionally ignored by Git.
The current build output remains in the root `build/` directory.

## Active resources

The files below remain in `Resources/` because the current app uses them:

- `AppIcon.icns`
- `AppIcon.png`
- `default.png`
