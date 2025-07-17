const fs = require('fs');
const path = require('path');
const RaindropAPI = require('./raindrop_api');
const config = require('./config');

class TestUploader {
  constructor() {
    this.api = new RaindropAPI();
  }

  /**
   * Test API connection
   */
  async testConnection() {
    try {
      console.log('🔗 Testing API connection...');
      const user = await this.api.testConnection();
      console.log(`✅ Connected as: ${user.item.fullName} (${user.item.email})`);
      return true;
    } catch (error) {
      console.error('❌ API connection failed:', error.message);
      return false;
    }
  }

  /**
   * List user's collections
   */
  async listCollections() {
    try {
      console.log('📂 Fetching collections...');
      const collections = await this.api.getCollections();
      console.log('Available collections:');
      collections.items.forEach(collection => {
        console.log(`  - ${collection.title} (ID: ${collection._id}) - ${collection.count} items`);
      });
      return collections;
    } catch (error) {
      console.error('❌ Failed to fetch collections:', error.message);
      return null;
    }
  }

  /**
   * Create a test screenshot file
   */
  createTestFile() {
    const testFileName = `Screenshot ${new Date().toISOString().replace(/:/g, '.')}.png`;
    const testFilePath = path.join(__dirname, testFileName);
    
    // Create a simple test file (1x1 PNG)
    const pngData = Buffer.from([
      0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
      0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
      0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
      0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
      0x89, 0x00, 0x00, 0x00, 0x0B, 0x49, 0x44, 0x41,
      0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
      0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00,
      0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE,
      0x42, 0x60, 0x82
    ]);
    
    fs.writeFileSync(testFilePath, pngData);
    console.log(`📸 Created test screenshot: ${testFileName}`);
    return testFilePath;
  }

  /**
   * Test file upload
   */
  async testUpload(filePath) {
    try {
      console.log(`📤 Testing upload of: ${path.basename(filePath)}`);
      
      // Check if file exists
      if (!fs.existsSync(filePath)) {
        throw new Error(`File not found: ${filePath}`);
      }

      // Check if it matches screenshot pattern
      const filename = path.basename(filePath);
      if (!config.isScreenshotFile(filename)) {
        console.warn(`⚠️  Warning: File doesn't match screenshot pattern: ${filename}`);
      }

      // Upload file
      const result = await this.api.uploadFile(filePath, {
        title: `Test Upload - ${new Date().toLocaleString()}`,
        excerpt: `Test upload on ${new Date().toLocaleDateString()}`
      });

      console.log('✅ Upload successful!');
      console.log('Response:', JSON.stringify(result, null, 2));
      
      return result;
    } catch (error) {
      console.error('❌ Upload failed:', error.message);
      if (error.response?.data) {
        console.error('API Error Details:', JSON.stringify(error.response.data, null, 2));
      }
      throw error;
    }
  }

  /**
   * Test duplicate checking
   */
  async testDuplicateCheck(filename) {
    try {
      console.log(`🔍 Checking for duplicates of: ${filename}`);
      const isDuplicate = await this.api.checkDuplicate(filename);
      console.log(`Result: ${isDuplicate ? 'Duplicate found' : 'No duplicates'}`);
      return isDuplicate;
    } catch (error) {
      console.error('❌ Duplicate check failed:', error.message);
      return false;
    }
  }

  /**
   * Clean up test files
   */
  cleanupTestFiles() {
    const testFiles = fs.readdirSync(__dirname).filter(file => 
      file.startsWith('Screenshot') && file.endsWith('.png')
    );
    
    testFiles.forEach(file => {
      const filePath = path.join(__dirname, file);
      fs.unlinkSync(filePath);
      console.log(`🗑️  Deleted test file: ${file}`);
    });
  }
}

/**
 * Main test function
 */
async function runTests() {
  const tester = new TestUploader();
  
  try {
    console.log('🧪 Starting Raindrop.io API Tests\n');
    
    // Test 1: API Connection
    console.log('=== Test 1: API Connection ===');
    const connected = await tester.testConnection();
    if (!connected) {
      console.error('❌ Cannot proceed without API connection');
      process.exit(1);
    }
    console.log('');

    // Test 2: List Collections
    console.log('=== Test 2: List Collections ===');
    await tester.listCollections();
    console.log('');

    // Test 3: Create and Upload Test File
    console.log('=== Test 3: Create and Upload Test File ===');
    const testFile = tester.createTestFile();
    await tester.testUpload(testFile);
    console.log('');

    // Test 4: Duplicate Check
    console.log('=== Test 4: Duplicate Check ===');
    await tester.testDuplicateCheck(path.basename(testFile));
    console.log('');

    // Test 5: Upload Real Screenshot (if provided)
    if (process.argv[2]) {
      console.log('=== Test 5: Upload Real File ===');
      const realFile = path.resolve(process.argv[2]);
      await tester.testUpload(realFile);
      console.log('');
    }

    console.log('✅ All tests completed successfully!');
    
  } catch (error) {
    console.error('❌ Test failed:', error.message);
    process.exit(1);
  } finally {
    // Clean up test files
    tester.cleanupTestFiles();
  }
}

// Run tests if this file is executed directly
if (require.main === module) {
  console.log('Usage: node test_upload.js [optional-file-path]');
  console.log('Example: node test_upload.js ~/Desktop/Screenshot\\ 2024-01-01\\ at\\ 10.30.45.png\n');
  
  runTests().catch(error => {
    console.error('❌ Fatal error:', error.message);
    process.exit(1);
  });
}

module.exports = TestUploader; 