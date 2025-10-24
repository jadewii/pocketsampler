#!/bin/bash
# Create an Xcode project for SamplerApp

PROJECT_DIR="/Users/jade/Documents/SamplerApp"
PROJECT_NAME="SamplerApp"

cd "$PROJECT_DIR"

# Use xcodegen if available, otherwise create manually
if command -v xcodegen &> /dev/null; then
    echo "Using xcodegen..."
    cat > project.yml << 'EOF'
name: SamplerApp
options:
  bundleIdPrefix: com.jadewii
targets:
  SamplerApp:
    type: application
    platform: iOS
    deploymentTarget: "16.0"
    sources:
      - SamplerApp
    settings:
      INFOPLIST_FILE: SamplerApp/Info.plist
      PRODUCT_BUNDLE_IDENTIFIER: com.jadewii.SamplerApp
      DEVELOPMENT_TEAM: ""
EOF
    xcodegen generate
else
    echo "xcodegen not found. Creating project manually..."
    # Create using command line
    echo "Opening Xcode to create project..."
    open -a Xcode
fi
