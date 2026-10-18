import java.util.Base64

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// The assistant ("Instinct, ...") is compiled in only when the app is built
// with --dart-define=ASSISTANT=true, the same define that `kAssistant` in
// lib/config/features.dart reads. `flutter run` and `flutter build` hand every
// define to Gradle as the one property `dart-defines`, each base64-encoded and
// comma-separated, so reading it here means the Dart half and the Android half
// cannot be built out of step. Without it, src/noAssistant is compiled instead
// of src/assistant, and the Undo receiver is not in the manifest.
val assistant: Boolean =
    (findProperty("dart-defines") as String?)
        ?.split(',')
        ?.map { String(Base64.getDecoder().decode(it)) }
        ?.contains("ASSISTANT=true") == true

android {
    namespace = "com.ganeshsharma.voicenotetaker_app"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.ganeshsharma.voicenotetaker_app"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    sourceSets {
        getByName("main") {
            java.directories.add(if (assistant) "src/assistant/kotlin" else "src/noAssistant/kotlin")
        }
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

androidComponents {
    onVariants { variant ->
        if (assistant) {
            variant.sources.manifests.addStaticManifestFile("src/assistant/AndroidManifest.xml")
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
