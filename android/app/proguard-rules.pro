# Keep flutter_background_service classes
-keep class id.flutter.flutter_background_service.** { *; }

# Keep the Dart VM entry points (background isolate callbacks)
-keep class io.flutter.** { *; }
-keep class io.flutter.plugins.** { *; }

# flutter_local_notifications
-keep class com.dexterous.** { *; }
