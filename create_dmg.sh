#!/bin/bash

APP_NAME="Prism"
DMG_NAME="Prism_Installer"
APP_PATH="./${APP_NAME}.app"
SOURCE_FOLDER="./dmg_source"

# Check if the app exists
if [ ! -d "$APP_PATH" ]; then
    echo "Error: $APP_PATH not found. Please run ./create_app.sh first."
    exit 1
fi

# Clean up previous builds
rm -rf "$SOURCE_FOLDER"
rm -f "${DMG_NAME}.dmg"

# Create source folder
mkdir "$SOURCE_FOLDER"

# Copy App to source folder
echo "Copying $APP_NAME.app..."
cp -r "$APP_PATH" "$SOURCE_FOLDER/"

# Create link to Applications folder
echo "Creating Applications link..."
ln -s /Applications "$SOURCE_FOLDER/Applications"

# Create DMG
echo "Creating DMG..."
hdiutil create -volname "$APP_NAME Installer" -srcfolder "$SOURCE_FOLDER" -ov -format UDZO "${DMG_NAME}.dmg"

# Clean up
rm -rf "$SOURCE_FOLDER"

echo "Done! ${DMG_NAME}.dmg created."
