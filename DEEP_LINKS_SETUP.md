# Deep Links for WhatsApp Invites

Current live invite domain in this project is:
- `https://noon-8531a.web.app/invite/<CODE>`

To make a WhatsApp invite open the app directly:

1. Host these files on your domain:
   - `https://noon-8531a.web.app/.well-known/assetlinks.json`
   - `https://noon-8531a.web.app/.well-known/apple-app-site-association`
2. Android:
   - Update `web/.well-known/assetlinks.json` with your **release** SHA-256 certificate fingerprint too (current file includes debug fingerprint only).
3. iOS:
   - Replace `TEAM_ID` in `web/.well-known/apple-app-site-association` with your Apple Team ID.
4. Ensure the app bundle/package IDs match:
   - Android package: `com.example.noon_chat`
   - iOS bundle: `com.example.noonChat`

If these `.well-known` files are missing or incorrect, WhatsApp links may open browser instead of the app.
