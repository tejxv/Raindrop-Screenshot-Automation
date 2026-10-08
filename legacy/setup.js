const fs = require('fs');
const path = require('path');
const readline = require('readline');

class SetupWizard {
  constructor() {
    this.rl = readline.createInterface({
      input: process.stdin,
      output: process.stdout
    });
    this.config = {};
  }

  question(prompt) {
    return new Promise(resolve => {
      this.rl.question(prompt, resolve);
    });
  }

  async run() {
    console.log('🚀 Raindrop Screenshot Automation Setup\n');
    
    try {
      // Check if .env already exists
      if (fs.existsSync('.env')) {
        const overwrite = await this.question('⚠️  .env file already exists. Overwrite? (y/N): ');
        if (overwrite.toLowerCase() !== 'y') {
          console.log('Setup cancelled.');
          this.rl.close();
          return;
        }
      }

      // Collect configuration
      await this.collectConfig();
      
      // Create .env file
      await this.createEnvFile();
      
      // Test configuration
      await this.testConfiguration();
      
      console.log('\n✅ Setup complete!');
      console.log('📖 Next steps:');
      console.log('   1. Run: npm start');
      console.log('   2. Take a screenshot to test');
      console.log('   3. Check your Raindrop.io account for the upload');
      
    } catch (error) {
      console.error('❌ Setup failed:', error.message);
    } finally {
      this.rl.close();
    }
  }

  async collectConfig() {
    console.log('📋 Configuration:\n');
    
    // Access Token
    this.config.accessToken = await this.question('🔑 Raindrop.io Access Token: ');
    if (!this.config.accessToken) {
      throw new Error('Access token is required');
    }
    
    // Refresh Token (optional)
    this.config.refreshToken = await this.question('🔄 Refresh Token (optional): ');
    
    // Collection ID
    this.config.collectionId = await this.question('📂 Collection ID (optional): ');
    
    // Screenshot Folder
    const defaultFolder = path.join(process.env.HOME, 'Desktop');
    this.config.screenshotFolder = await this.question(`📁 Screenshot Folder (${defaultFolder}): `) || defaultFolder;
    
    // Upload Folder
    const defaultUploadFolder = path.join(process.env.HOME, 'Screenshots', 'Uploaded');
    this.config.uploadFolder = await this.question(`📤 Upload Folder (${defaultUploadFolder}): `) || defaultUploadFolder;
    
    // Tags
    this.config.tags = await this.question('🏷️  Tags (screenshot,macos): ') || 'screenshot,macos';
    
    // Auto Delete
    const autoDelete = await this.question('🗑️  Auto-delete after upload? (y/N): ');
    this.config.autoDelete = autoDelete.toLowerCase() === 'y';
    
    // Notifications
    const notifications = await this.question('📱 Enable notifications? (Y/n): ');
    this.config.notifications = notifications.toLowerCase() !== 'n';
  }

  async createEnvFile() {
    const envContent = `# Raindrop.io API Configuration
RAINDROP_ACCESS_TOKEN=${this.config.accessToken}
${this.config.refreshToken ? `RAINDROP_REFRESH_TOKEN=${this.config.refreshToken}` : '# RAINDROP_REFRESH_TOKEN='}
${this.config.collectionId ? `RAINDROP_COLLECTION_ID=${this.config.collectionId}` : '# RAINDROP_COLLECTION_ID='}

# Screenshot Configuration
SCREENSHOT_FOLDER=${this.config.screenshotFolder}
UPLOADED_FOLDER=${this.config.uploadFolder}

# Optional Configuration
TAGS=${this.config.tags}
AUTO_DELETE=${this.config.autoDelete}
NOTIFICATIONS=${this.config.notifications}

# Test Configuration (for development)
# TEST_TOKEN=test_token_here
`;

    fs.writeFileSync('.env', envContent);
    console.log('\n✅ Created .env file');
  }

  async testConfiguration() {
    console.log('\n🧪 Testing configuration...');
    
    try {
      // Test if screenshot folder exists
      if (!fs.existsSync(this.config.screenshotFolder)) {
        console.log(`⚠️  Screenshot folder doesn't exist: ${this.config.screenshotFolder}`);
        const create = await this.question('Create it? (y/N): ');
        if (create.toLowerCase() === 'y') {
          fs.mkdirSync(this.config.screenshotFolder, { recursive: true });
          console.log('✅ Created screenshot folder');
        }
      } else {
        console.log('✅ Screenshot folder exists');
      }
      
      // Test if upload folder exists or create it
      if (!fs.existsSync(this.config.uploadFolder)) {
        fs.mkdirSync(this.config.uploadFolder, { recursive: true });
        console.log('✅ Created upload folder');
      } else {
        console.log('✅ Upload folder exists');
      }
      
      // Test API connection
      const { RaindropAPI } = require('./raindrop_api');
      const api = new RaindropAPI();
      
      console.log('🔗 Testing API connection...');
      const user = await api.testConnection();
      console.log(`✅ Connected as: ${user.item.fullName}`);
      
    } catch (error) {
      console.log(`❌ Configuration test failed: ${error.message}`);
      console.log('You can still proceed, but you may need to fix issues later.');
    }
  }
}

// Run setup if this file is executed directly
if (require.main === module) {
  const wizard = new SetupWizard();
  wizard.run();
}

module.exports = SetupWizard; 