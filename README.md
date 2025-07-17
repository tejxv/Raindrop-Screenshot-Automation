# Raindrop Screenshot Automation

A macOS-native Node.js utility that automatically watches for new screenshots and uploads them to Raindrop.io using their REST API. Can run as a background daemon or manually.

## Features

✨ **Core Features:**
- 🔍 Continuously monitors screenshot folder (~/Desktop by default)
- 📸 Automatically detects macOS screenshot files (Screenshot YYYY-MM-DD at HH.MM.SS.png)
- 📤 Uploads screenshots to Raindrop.io as file-type raindrops
- 🔐 OAuth 2.0 authentication with token refresh support
- 🏷️ Configurable tags and collection assignment
- 📱 macOS Notification Center integration with clickable URLs
- 📁 Automatic file organization (move to uploaded folder or delete)

🔧 **Advanced Features:**
- 🚫 Duplicate detection and prevention
- 🔄 Automatic token refresh when expired
- 📝 Detailed logging and error handling
- 🧪 Comprehensive testing utilities
- ⚙️ Highly configurable via environment variables

🚀 **Background Service Features:**
- 🛠️ **Daemon Mode**: Runs as a background service on macOS
- 🔄 **Auto-start**: Automatically starts on login
- 🔗 **Clickable Notifications**: Click notifications to open uploaded screenshots
- 📊 **Quota Monitoring**: Real-time storage quota notifications
- 📋 **Service Management**: Easy start/stop/restart commands

## Prerequisites

- Node.js 14 or higher
- macOS (for screenshot detection patterns and notifications)
- Raindrop.io account with API access

## Installation

1. Clone or download this repository
2. Install dependencies:
   ```bash
   npm install
   ```

3. Run the setup wizard:
   ```bash
   npm run setup
   ```

   Or manually create a `.env` file based on the template:
   ```bash
   cp config.template .env
   ```

4. Configure your settings in `.env`:
   ```env
   RAINDROP_ACCESS_TOKEN=your_access_token_here
   RAINDROP_REFRESH_TOKEN=your_refresh_token_here
   RAINDROP_COLLECTION_ID=123456
   SCREENSHOT_FOLDER=/Users/tejas/Desktop
   UPLOADED_FOLDER=/Users/tejas/Screenshots/Uploaded
   TAGS=screenshot,macos
   AUTO_DELETE=false
   NOTIFICATIONS=true
   ```

## Getting API Credentials

1. Visit [Raindrop.io App Center](https://app.raindrop.io/settings/integrations)
2. Create a new app or use an existing one
3. Generate an access token
4. Optionally, set up OAuth 2.0 for refresh tokens

## Usage

### Option 1: Background Daemon (Recommended)

**Install the daemon** (runs automatically on login):
```bash
npm run daemon install
```

**Manage the daemon**:
```bash
# Check status
npm run daemon status

# View logs
npm run daemon logs

# View errors
npm run daemon errors

# Start/stop/restart
npm run daemon start
npm run daemon stop
npm run daemon restart

# Remove daemon
npm run daemon uninstall
```

### Option 2: Manual Mode

```bash
npm start
# or
node watcher.js
```

The watcher will:
- Monitor your screenshot folder for new files
- Automatically upload matching screenshots to Raindrop.io
- Show **two types of notifications**:
  1. **Upload Success**: Shows filename with clickable "Show" button to open screenshot
  2. **Storage Quota**: Shows remaining storage (e.g., "86.37MB remaining of 95.37MB (9% used)")
- Move uploaded files to the configured folder

## Enhanced Notification System

When you take a screenshot, you'll receive:

### 1. Upload Success Notification
- **Title**: "Raindrop Upload Success"
- **Message**: "Uploaded: Screenshot-filename.png"
- **Action**: Click notification or "Show" button to open the uploaded screenshot in your browser
- **URL**: Direct link to S3-hosted screenshot

### 2. Storage Quota Notification
- **Title**: "Storage Quota"
- **Message**: "86.37MB remaining of 95.37MB (9% used)"
- **Features**:
  - Real-time quota information
  - Works for both free (100MB) and pro (10GB) accounts
  - Updates after each upload
  - Shows remaining space and usage percentage

## Testing

### Test the Configuration

```bash
npm test
# or
node test_upload.js
```

This will:
- Test API connection
- List your collections
- Create and upload a test file
- Check duplicate detection
- Clean up test files

### Test with a Real File

```bash
node test_upload.js "/path/to/your/screenshot.png"
```

## Configuration Options

All configuration is done via environment variables in your `.env` file:

| Variable | Description | Default |
|----------|-------------|---------|
| `RAINDROP_ACCESS_TOKEN` | Your Raindrop.io access token | **Required** |
| `RAINDROP_REFRESH_TOKEN` | OAuth refresh token (optional) | None |
| `RAINDROP_COLLECTION_ID` | Target collection ID | None (uses default) |
| `SCREENSHOT_FOLDER` | Folder to watch for screenshots | `~/Desktop` |
| `UPLOADED_FOLDER` | Where to move uploaded files | `~/Screenshots/Uploaded` |
| `TAGS` | Comma-separated tags to apply | `screenshot,macos` |
| `AUTO_DELETE` | Delete files after upload | `false` |
| `NOTIFICATIONS` | Enable macOS notifications | `true` |

## Screenshot Detection

The utility automatically detects macOS screenshot files by checking:
- Filename starts with "Screenshot"
- Valid image extension (`.png`, `.jpg`, `.jpeg`)

This catches all macOS screenshot variations including:
- `Screenshot 2024-01-01 at 10.30.45.png`
- `Screenshot 2024-01-01 at 10.30.45 AM.png`
- `Screenshot 2024-01-01 at 10.30.45 PM.png`
- `Screenshot 2025-07-17 at 1.38.52 PM (2).png` (duplicates)
- Any other macOS screenshot naming pattern

## Apple Silicon Mac Compatibility

This utility is fully compatible with Apple Silicon Macs. The daemon automatically detects and uses the correct Node.js path:
- **Intel Macs**: `/usr/local/bin/node`
- **Apple Silicon Macs**: `/opt/homebrew/bin/node`

If you encounter daemon startup issues, ensure Node.js is installed via Homebrew:
```bash
brew install node
```

## API Integration

### Authentication
- Uses OAuth 2.0 Bearer token authentication
- Automatically refreshes tokens when expired (if refresh token provided)
- Handles authentication errors gracefully

### File Upload
- Uses `PUT /raindrop/file` endpoint
- Sends files as `multipart/form-data`
- Includes metadata (title, excerpt, tags, collection)
- Handles file validation and size limits
- Returns S3 URL for uploaded files

### Quota Monitoring
- Uses `GET /user` endpoint to fetch storage information
- Calculates remaining space and usage percentage
- Supports both free (100MB) and pro (10GB) accounts
- Updates quota information after each upload

### Error Handling
- Detailed error logging for debugging
- Handles specific API errors (`file_invalid`, `file_size_limit`, `no file`)
- Graceful fallbacks for network issues

## File Structure

```
raindrop-screenshot-automation/
├── package.json                           # Project dependencies
├── config.js                             # Configuration management
├── raindrop_api.js                       # API client and authentication
├── watcher.js                            # Main file watcher logic
├── test_upload.js                        # Testing utilities
├── daemon-manager.js                     # Daemon management utility
├── com.raindrop.screenshot.automation.plist # macOS LaunchAgent configuration
├── config.template                       # Environment variable template
└── README.md                            # This file
```

## Troubleshooting

### Common Issues

**"RAINDROP_ACCESS_TOKEN is required"**
- Ensure you've created a `.env` file with your access token
- Verify the token is valid by running the test script

**"Screenshot folder does not exist"**
- Check the `SCREENSHOT_FOLDER` path in your `.env` file
- Ensure the folder exists and is accessible

**"Failed to upload" errors**
- Run `node test_upload.js` to diagnose API issues
- Check your internet connection
- Verify your access token hasn't expired

**Files not being detected**
- Ensure files match the macOS screenshot naming pattern
- Check that files are `.png` or `.jpg` format
- Verify the watcher is monitoring the correct folder

**Daemon won't start**
- Check if Node.js is installed: `which node`
- For Apple Silicon Macs, ensure Homebrew is installed: `brew install node`
- Check daemon logs: `npm run daemon logs` and `npm run daemon errors`
- Reinstall daemon: `npm run daemon uninstall && npm run daemon install`

**Notifications not working**
- Ensure notifications are enabled in your `.env` file: `NOTIFICATIONS=true`
- Check macOS System Preferences > Notifications > Terminal (or your terminal app)
- Grant notification permissions if prompted

### Debug Mode

For additional debugging, you can:
1. Check the console output for detailed error messages
2. Run the test script to isolate issues: `npm test`
3. View daemon logs: `npm run daemon logs`
4. Check daemon status: `npm run daemon status`
5. Verify API responses in the test output

## Development

### Adding New Features

The codebase is modular and easy to extend:

- `config.js` - Add new configuration options
- `raindrop_api.js` - Add new API endpoints or methods
- `watcher.js` - Modify file watching or processing logic
- `test_upload.js` - Add new test scenarios
- `daemon-manager.js` - Enhance daemon management features

### Running Tests

```bash
# Run all tests
npm test

# Test specific functionality
node test_upload.js

# Test with custom file
node test_upload.js "/path/to/file.png"

# Test daemon functionality
npm run daemon status
npm run daemon logs
```

## Daemon Management Commands

| Command | Description |
|---------|-------------|
| `npm run daemon install` | Install daemon (auto-starts on login) |
| `npm run daemon uninstall` | Remove daemon completely |
| `npm run daemon start` | Start the daemon |
| `npm run daemon stop` | Stop the daemon |
| `npm run daemon restart` | Restart the daemon |
| `npm run daemon status` | Check if daemon is running |
| `npm run daemon logs` | View recent logs |
| `npm run daemon errors` | View recent errors |

## Stretch Goals (Future Development)

- 🍎 Package as a macOS menu bar app
- 🎨 GUI for configuration management
- 🔍 More sophisticated duplicate detection
- 📊 Upload statistics and monitoring dashboard
- 🔒 macOS Keychain integration for token storage
- 📱 iOS companion app integration
- 🌐 Cross-platform support (Windows, Linux)

## Contributing

1. Fork the repository
2. Create a feature branch
3. Make your changes
4. Add tests for new functionality
5. Submit a pull request

## License

MIT License - see LICENSE file for details

## Support

For issues or questions:
1. Check the troubleshooting section
2. Run the test script for diagnostics: `npm test`
3. Check daemon logs: `npm run daemon logs`
4. Check Raindrop.io API documentation
5. Create an issue in the repository

---

**Note:** This utility is designed for macOS and uses macOS-specific screenshot patterns and notification systems. While the core functionality may work on other platforms, full compatibility is not guaranteed. 