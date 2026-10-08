const chokidar = require('chokidar');
const path = require('path');
const fs = require('fs');
const notifier = require('node-notifier');
const { exec } = require('child_process');
const config = require('./config');
const RaindropAPI = require('./raindrop_api');

class ScreenshotWatcher {
  constructor() {
    this.api = new RaindropAPI();
    this.watcherConfig = config.getConfig();
    this.processedFiles = new Set();
    this.watcher = null;
  }

  /**
   * Initialize the watcher
   */
  async init() {
    try {
      console.log('🚀 Starting Raindrop Screenshot Automation...');
      console.log(`📁 Watching folder: ${this.watcherConfig.screenshotFolder}`);
      console.log(`📤 Upload folder: ${this.watcherConfig.uploadedFolder}`);
      console.log(`🏷️  Tags: ${this.watcherConfig.tags.join(', ')}`);
      
      // Test API connection
      await this.api.testConnection();
      
      // Start watching
      this.startWatching();
      
    } catch (error) {
      console.error('❌ Failed to initialize:', error.message);
      this.notify('Raindrop Watcher Error', 'Failed to initialize. Check your configuration.');
      process.exit(1);
    }
  }

  /**
   * Start file system watcher
   */
  startWatching() {
    const watchPath = this.watcherConfig.screenshotFolder;
    
    // Ensure watch directory exists
    if (!fs.existsSync(watchPath)) {
      console.error(`❌ Screenshot folder does not exist: ${watchPath}`);
      return;
    }

    this.watcher = chokidar.watch(watchPath, {
      ignored: [
        /(^|[\/\\])\../, // ignore dotfiles
        /node_modules/,
        this.watcherConfig.uploadedFolder // ignore upload folder
      ],
      persistent: true,
      ignoreInitial: true, // Don't process existing files
      awaitWriteFinish: {
        stabilityThreshold: 1000, // Wait 1 second for file to stabilize
        pollInterval: 100
      }
    });

    this.watcher
      .on('add', (filePath) => this.handleNewFile(filePath))
      .on('error', (error) => console.error('❌ Watcher error:', error))
      .on('ready', () => {
        console.log('👀 Watcher is ready and monitoring for new screenshots...');
        this.notify('Raindrop Watcher', 'Started monitoring for new screenshots');
      });

    // Handle process termination
    process.on('SIGINT', () => {
      console.log('\n📴 Stopping watcher...');
      this.stopWatching();
      process.exit(0);
    });
  }

  /**
   * Handle new file detection
   */
  async handleNewFile(filePath) {
    try {
      const filename = path.basename(filePath);
      const fullPath = path.resolve(filePath);

      // Check if it's a screenshot file
      if (!config.isScreenshotFile(filename)) {
        console.log(`⏭️  Skipping non-screenshot file: ${filename}`);
        return;
      }

      // Check if already processed
      if (this.processedFiles.has(fullPath)) {
        console.log(`⏭️  File already processed: ${filename}`);
        return;
      }

      console.log(`📸 New screenshot detected: ${filename}`);
      this.processedFiles.add(fullPath);

      // Check for duplicates if enabled
      const isDuplicate = await this.api.checkDuplicate(filename);
      if (isDuplicate) {
        console.log(`⏭️  Duplicate detected, skipping: ${filename}`);
        this.notify('Raindrop Watcher', `Skipped duplicate: ${filename}`);
        return;
      }

      // Upload to Raindrop.io
      await this.uploadScreenshot(fullPath);

    } catch (error) {
      console.error(`❌ Error processing file ${path.basename(filePath)}:`, error.message);
      this.notify('Raindrop Upload Error', `Failed to upload ${path.basename(filePath)}: ${error.message}`);
    }
  }

  /**
   * Upload screenshot to Raindrop.io
   */
  async uploadScreenshot(filePath) {
    try {
      const filename = path.basename(filePath);
      
      // Upload file
      const uploadResponse = await this.api.uploadFile(filePath, {
        title: `Screenshot - ${new Date().toLocaleString()}`,
        excerpt: `Screenshot taken on ${new Date().toLocaleDateString()}`
      });

      // Handle successful upload
      await this.handleSuccessfulUpload(filePath, uploadResponse);

    } catch (error) {
      console.error(`❌ Upload failed for ${path.basename(filePath)}:`, error.message);
      this.notify('Raindrop Upload Failed', `Failed to upload ${path.basename(filePath)}`);
      throw error;
    }
  }

  /**
   * Handle successful upload
   */
  async handleSuccessfulUpload(filePath, uploadResponse) {
    const filename = path.basename(filePath);
    
    console.log(`✅ Successfully uploaded: ${filename}`);
    
    // Extract the URL from the upload response
    const screenshotUrl = uploadResponse?.item?.link;
    
    if (screenshotUrl) {
      console.log(`🔗 Screenshot URL: ${screenshotUrl}`);
      this.notify('Raindrop Upload Success', `Uploaded: ${filename}`, screenshotUrl);
    } else {
      this.notify('Raindrop Upload Success', `Uploaded: ${filename}`);
    }

    // Get and display quota information
    try {
      const quota = await this.api.getUserQuota();
      if (quota) {
        const quotaMessage = `${quota.remainingMB}MB remaining of ${quota.totalMB}MB (${quota.usedPercent}% used)`;
        console.log(`📊 Storage quota: ${quotaMessage}`);
        
        // Send quota notification
        setTimeout(() => {
          this.notify('Storage Quota', quotaMessage);
        }, 1000); // Delay to avoid notification overlap
      }
    } catch (error) {
      console.warn('⚠️ Could not retrieve quota information:', error.message);
    }

    // Move or delete file based on configuration
    if (this.watcherConfig.autoDelete) {
      await this.deleteFile(filePath);
    } else {
      await this.moveFile(filePath);
    }
  }

  /**
   * Move file to uploaded folder
   */
  async moveFile(filePath) {
    try {
      const filename = path.basename(filePath);
      const destinationPath = path.join(this.watcherConfig.uploadedFolder, filename);
      
      // Handle file name conflicts
      const finalDestination = this.getUniqueFilename(destinationPath);
      
      await fs.promises.rename(filePath, finalDestination);
      console.log(`📁 Moved to: ${finalDestination}`);
      
    } catch (error) {
      console.error(`❌ Failed to move file:`, error.message);
    }
  }

  /**
   * Delete file after upload
   */
  async deleteFile(filePath) {
    try {
      await fs.promises.unlink(filePath);
      console.log(`🗑️  Deleted: ${path.basename(filePath)}`);
    } catch (error) {
      console.error(`❌ Failed to delete file:`, error.message);
    }
  }

  /**
   * Get unique filename to avoid conflicts
   */
  getUniqueFilename(filePath) {
    let counter = 1;
    let basePath = filePath;
    const ext = path.extname(filePath);
    const name = path.basename(filePath, ext);
    const dir = path.dirname(filePath);

    while (fs.existsSync(basePath)) {
      basePath = path.join(dir, `${name} (${counter})${ext}`);
      counter++;
    }

    return basePath;
  }

  /**
   * Send macOS notification with optional URL action
   */
  notify(title, message, url = null) {
    if (!this.watcherConfig.notifications) return;

    const notificationConfig = {
      title: title,
      message: message,
      icon: path.join(__dirname, 'icon.png'), // Optional icon
      sound: true,
      wait: false
    };

    // Add actions if URL is provided
    if (url) {
      notificationConfig.actions = ['Show'];
      notificationConfig.dropdownLabel = 'Actions';
      notificationConfig.wait = true; // Wait for user interaction
    }

    const notification = notifier.notify(notificationConfig);

    // Handle notification click events
    if (url) {
      notification.on('click', () => {
        this.openUrl(url);
      });

      notification.on('activate', () => {
        this.openUrl(url);
      });

      notification.on('show', () => {
        this.openUrl(url);
      });
    }
  }

  /**
   * Open URL in default browser
   */
  openUrl(url) {
    const command = process.platform === 'darwin' ? 'open' : 
                   process.platform === 'win32' ? 'start' : 'xdg-open';
    
    exec(`${command} "${url}"`, (error) => {
      if (error) {
        console.error(`❌ Failed to open URL: ${error.message}`);
      } else {
        console.log(`🌐 Opened URL: ${url}`);
      }
    });
  }

  /**
   * Stop the watcher
   */
  stopWatching() {
    if (this.watcher) {
      this.watcher.close();
      console.log('📴 Watcher stopped');
    }
  }

  /**
   * Get watcher statistics
   */
  getStats() {
    return {
      processedFiles: this.processedFiles.size,
      isWatching: this.watcher && !this.watcher.closed
    };
  }
}

// Run the watcher if this file is executed directly
if (require.main === module) {
  const watcher = new ScreenshotWatcher();
  watcher.init().catch(error => {
    console.error('❌ Fatal error:', error.message);
    process.exit(1);
  });
}

module.exports = ScreenshotWatcher; 