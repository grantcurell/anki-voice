# Xcode Configuration Steps

## Required Xcode Settings Changes

To complete the compilation error fixes, you need to configure the following in Xcode:

### 1. Add Build Flag for Debug Configuration

1. Open your Xcode project
2. Select the **AnkiVoice** target
3. Go to **Build Settings** tab
4. Search for **"Other Swift Flags"**
5. Expand the setting
6. For **Debug** configuration, add: `-D NO_SIWA`
7. Leave **Release** configuration empty (or add `-D USE_SIWA` if you prefer)

### 2. Configure Entitlements Files

1. Still in **Build Settings**, search for **"Code Signing Entitlements"**
2. Expand the setting
3. For **Debug** configuration, set to: `AnkiVoice/AnkiVoice/AnkiVoice.Debug.entitlements`
4. For **Release** configuration, set to: `AnkiVoice/AnkiVoice/AnkiVoice.Release.entitlements`

### 3. Verify Files Are Added to Target

Make sure these files are included in your Xcode project and added to the target:
- `AnkiVoice.Debug.entitlements` ✓
- `AnkiVoice.Release.entitlements` ✓
- `ContentViewHelpers.swift` ✓

## Summary of Changes Made

### Code Changes
1. ✅ Created two entitlements files (Debug without SiwA, Release with SiwA)
2. ✅ Fixed unused variable warning (`jwt` → `_`)
3. ✅ Fixed deprecated API usage (`UIApplication.shared.windows` → scene-based approach)
4. ✅ Wrapped Sign in with Apple code with `#if !NO_SIWA` conditional compilation
5. ✅ Split `ContentView` into smaller subviews to fix type-checking timeout
6. ✅ Updated switch statement error messages for clarity

### Files Created
- `AnkiVoice.Debug.entitlements` - Debug entitlements (no SiwA)
- `AnkiVoice.Release.entitlements` - Release entitlements (with SiwA)
- `ContentViewHelpers.swift` - Extracted subviews

### Files Modified
- `AuthService.swift` - Conditional compilation, fixed warnings, deprecated API
- `ContentView.swift` - Simplified by using extracted subviews

## Testing

After configuring Xcode:
1. Clean build folder: `Shift+Cmd+K`
2. Build for Debug: `Cmd+B`
3. Verify no compilation errors
4. Build for Release: `Cmd+B` (should also work)

## Notes

- Debug builds will compile without Sign in with Apple capability (works with personal dev teams)
- Release builds will include Sign in with Apple for App Store distribution
- The `NO_SIWA` flag controls conditional compilation throughout the codebase

