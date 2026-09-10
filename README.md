# HerCycle MVP

A Flutter-based menstrual cycle and wellness tracker.

## Setup Instructions

1. **Firebase Configuration:**
   - Create a Firebase project.
   - Run `flutterfire configure` to generate `lib/firebase_options.dart`.
   - Uncomment the `Firebase.initializeApp` call in `lib/main.dart` and the imports.

2. **Run the App:**
   ```bash
   flutter pub get
   flutter run
   ```

## Key Features

- **Authentication:** Firebase Auth (Email/Password).
- **Core Tracking:** Log periods, symptoms, and moods daily.
- **Insights:** Trends overview (basic).
- **Security:** Firestore security rules implemented for user data isolation.
