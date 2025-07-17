# Raindrop Screenshot Automation

A macOS-native Node.js utility that automatically watches for new screenshots and uploads them to Raindrop.io using their REST API.

## Features

✨ **Core Features:**
- 🔍 Continuously monitors screenshot folder (~/Desktop by default)
- 📸 Automatically detects macOS screenshot files (Screenshot YYYY-MM-DD at HH.MM.SS.png)
- 📤 Uploads screenshots to Raindrop.io as file-type raindrops
- 🔐 OAuth 2.0 authentication with token refresh support
- 🏷️ Configurable tags and collection assignment
- 📱 macOS Notification Center integration
- 📁 Automatic file organization (move to uploaded folder or delete)

🔧 **Advanced Features:**
- 🚫 Duplicate detection and prevention
- 🔄 Automatic token refresh when expired
- 📝 Detailed logging and error handling
- 🧪 Comprehensive testing utilities
- ⚙️ Highly configurable via environment variables

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

### Start the Watcher

```bash
npm start
# or
node watcher.js
```

The watcher will:
- Monitor your screenshot folder for new files
- Automatically upload matching screenshots to Raindrop.io
- Show notifications for successful uploads
- Move uploaded files to the configured folder

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

### Error Handling
- Detailed error logging for debugging
- Handles specific API errors (`file_invalid`, `file_size_limit`, `no file`)
- Graceful fallbacks for network issues

## File Structure

```
raindrop-screenshot-automation/
├── package.json          # Project dependencies
├── config.js            # Configuration management
├── raindrop_api.js      # API client and authentication
├── watcher.js           # Main file watcher logic
├── test_upload.js       # Testing utilities
├── config.template      # Environment variable template
└── README.md           # This file
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

### Debug Mode

For additional debugging, you can:
1. Check the console output for detailed error messages
2. Run the test script to isolate issues
3. Verify API responses in the test output

## Development

### Adding New Features

The codebase is modular and easy to extend:

- `config.js` - Add new configuration options
- `raindrop_api.js` - Add new API endpoints or methods
- `watcher.js` - Modify file watching or processing logic
- `test_upload.js` - Add new test scenarios

### Running Tests

```bash
# Run all tests
npm test

# Test specific functionality
node test_upload.js

# Test with custom file
node test_upload.js "/path/to/file.png"
```

## Stretch Goals (Future Development)

- 🍎 Package as a macOS menu bar app
- 🎨 GUI for configuration management
- 🔍 More sophisticated duplicate detection
- 📊 Upload statistics and monitoring
- 🔒 macOS Keychain integration for token storage
- 📱 iOS companion app integration

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
2. Run the test script for diagnostics
3. Check Raindrop.io API documentation
4. Create an issue in the repository

---

**Note:** This utility is designed for macOS and uses macOS-specific screenshot patterns and notification systems. While the core functionality may work on other platforms, full compatibility is not guaranteed. 