const dotenv = require('dotenv');
const path = require('path');
const fs = require('fs');
const os = require('os');

// Load environment variables
dotenv.config();

class Config {
  constructor() {
    this.loadConfig();
  }

  loadConfig() {
    // Raindrop.io API Configuration
    this.accessToken = process.env.RAINDROP_ACCESS_TOKEN || process.env.TEST_TOKEN;
    this.refreshToken = process.env.RAINDROP_REFRESH_TOKEN;
    this.collectionId = process.env.RAINDROP_COLLECTION_ID || null;

    // Screenshot Configuration
    this.screenshotFolder = process.env.SCREENSHOT_FOLDER || path.join(os.homedir(), 'Desktop');
    this.uploadedFolder = process.env.UPLOADED_FOLDER || path.join(os.homedir(), 'Screenshots', 'Uploaded');

    // Optional Configuration
    this.tags = process.env.TAGS ? process.env.TAGS.split(',').map(tag => tag.trim()) : ['screenshot', 'macos'];
    this.autoDelete = process.env.AUTO_DELETE === 'true';
    this.notifications = process.env.NOTIFICATIONS !== 'false';

    // Validate required configuration
    if (!this.accessToken) {
      throw new Error('RAINDROP_ACCESS_TOKEN is required. Please create a .env file or set environment variables.');
    }

    // Ensure upload folder exists
    this.ensureUploadFolder();
  }

  ensureUploadFolder() {
    if (!fs.existsSync(this.uploadedFolder)) {
      fs.mkdirSync(this.uploadedFolder, { recursive: true });
    }
  }

  // Screenshot naming pattern for macOS
  isScreenshotFile(filename) {
    // Simply check if filename starts with "Screenshot" and has valid image extension
    const startsWithScreenshot = filename.startsWith('Screenshot');
    const hasValidExtension = /\.(png|jpg|jpeg)$/i.test(filename);
    
    return startsWithScreenshot && hasValidExtension;
  }

  getConfig() {
    return {
      accessToken: this.accessToken,
      refreshToken: this.refreshToken,
      collectionId: this.collectionId,
      screenshotFolder: this.screenshotFolder,
      uploadedFolder: this.uploadedFolder,
      tags: this.tags,
      autoDelete: this.autoDelete,
      notifications: this.notifications
    };
  }
}

module.exports = new Config(); 