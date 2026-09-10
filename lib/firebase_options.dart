import 'package:flutter/foundation.dart';
import 'package:firebase_core/firebase_core.dart';

class DefaultFirebaseOptions {
  static FirebaseOptions get currentPlatform {
    if (kIsWeb) {
      return const FirebaseOptions(
        apiKey: "AIzaSyBwFjEwJTuuigHcH-oqXgGAsL3xjcpumP4",
        authDomain: "hercycle-f6839.firebaseapp.com",
        projectId: "hercycle-f6839",
        storageBucket: "hercycle-f6839.firebasestorage.app",
        messagingSenderId: "673908405697",
        appId: "1:673908405697:web:11cfb398e09a6d52fbeb40",
        measurementId: "G-KF997VWL03",
      );
    }
    // For Android/iOS, firebase_core uses the google-services.json/GoogleService-Info.plist
    // automatically if they are included in the build process.
    return const FirebaseOptions(
      apiKey: "",
      appId: "",
      messagingSenderId: "",
      projectId: "",
    );
  }
}
