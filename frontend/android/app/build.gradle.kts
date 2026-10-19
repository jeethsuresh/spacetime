plugins {
    id("com.android.application")
    id("kotlin-android")
    id("dev.flutter.flutter-gradle-plugin")
}
val releaseStore = System.getenv("SPACETIME_KEYSTORE")
android {
    namespace = "com.jeethsuresh.spacetime"
    compileSdk = 35
    ndkVersion = "27.0.12077973"
    compileOptions {
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
    }
    kotlinOptions { jvmTarget = JavaVersion.VERSION_11.toString() }
    defaultConfig {
        applicationId = "com.jeethsuresh.spacetime"
        minSdk = 23
        targetSdk = 35
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }
    sourceSets.getByName("test").resources.srcDir("../../test/fixtures")
    signingConfigs {
        if (releaseStore != null) create("release") {
            storeFile = file(releaseStore)
            storePassword = System.getenv("SPACETIME_STORE_PASSWORD")
            keyAlias = "spacetime-release"
            keyPassword = System.getenv("SPACETIME_KEY_PASSWORD")
        }
    }
    buildTypes {
        debug { applicationIdSuffix = ".dev" }
        release { signingConfig = signingConfigs.findByName("release") }
    }
}
val requireReleaseSigning = tasks.register("requireReleaseSigning") {
    doFirst { check(releaseStore != null) { "Set SPACETIME_KEYSTORE, SPACETIME_STORE_PASSWORD, and SPACETIME_KEY_PASSWORD for a signed release." } }
}
tasks.matching { it.name == "preReleaseBuild" }.configureEach { dependsOn(requireReleaseSigning) }
flutter { source = "../.." }

dependencies {
    implementation("org.dmfs:lib-recur:0.17.1")
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
    debugImplementation("androidx.test:runner:1.6.2")
    debugImplementation("androidx.test:rules:1.6.1")
    androidTestImplementation("androidx.test.ext:junit:1.2.1")
    androidTestImplementation("androidx.test:rules:1.6.1")
    androidTestImplementation("androidx.test:runner:1.6.2")
    testImplementation("junit:junit:4.13.2")
    testImplementation("org.json:json:20240303")
}
