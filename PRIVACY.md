# HerCycle Privacy Policy (Draft — review before publishing)

_Last updated: 2026-09-10. Replace contact details in §9 before release._

## 1. What HerCycle is
HerCycle is a menstrual-cycle and wellness tracker. Core tracking (periods, symptoms, moods, predictions, reports) runs on your device and syncs to your private Firebase account so your data follows you across devices.

## 2. Data we collect
- **Account identifiers:** name, email address, and authentication tokens (Firebase Authentication, including Google Sign-In).
- **Health-related data you enter:** period dates, symptoms, moods, mucus observations, LH test results, pain scores, notes, cycle lengths, and profile fields (date of birth, blood group). This is sensitive personal data and is treated accordingly.
- **Reports you generate:** clinical and Deep Insight reports are generated on-device from your data.
- **Diagnostics (if enabled):** crash reports via Firebase Crashlytics, if integrated.

## 3. What we do NOT collect
- No advertising identifiers, no sale of personal data, no third-party analytics SDKs beyond Firebase services.
- Daily reminder notifications are scheduled **locally on your device**; their content never leaves the phone.
- AI assistant replies (Luna) are computed from your logs; when the optional server mode is used, only the minimal data needed for the answer is transmitted.

## 4. Premium / blockchain payments (Deep Insight)
- The first Deep Insight report is free. Paid reports cost the displayed INR amount, settled as USDC micropayments on **Algorand TestNet** through the GoPlausible x402 facilitator.
- Only the payment receipt (transaction id, amount, timestamp) is stored, linked to your account to unlock the report. Your wallet keys never touch our systems.
- TestNet transactions carry no real-world monetary value.

## 5. Where data lives
- **Firebase (Google Cloud):** authentication records and your Firestore documents (`users/{uid}`, daily logs, cycle records, report receipts). Access is enforced per-user by Firestore Security Rules.
- **Your device:** local caches, scheduled reminders, app preferences.
- **Premium server (optional, when used):** health logs sent for a paid report are processed in memory per request and never persisted or logged.

## 6. Your rights and controls
- **Access/export:** view everything in-app (Profile, Trends, Health Reports) or export doctor-ready PDFs.
- **Delete everything:** Profile → "Delete account & all my data" permanently erases your Firestore records and your authentication account (in-app, no email required).
- **Notifications:** toggle daily reminders and reminder time in Profile; disabling deletes the scheduled alarm.

## 7. Children's privacy
HerCycle is not directed at children under 13 (or the minimum age in your jurisdiction). Accounts found to belong to children will be removed with their data.

## 8. Changes
Material changes will be announced in-app before taking effect. Continued use after the effective date constitutes acceptance.

## 9. Contact
Questions or deletion requests: **TODO — add support email / DPO contact before release.**
