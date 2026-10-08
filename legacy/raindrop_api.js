const axios = require('axios');
const FormData = require('form-data');
const fs = require('fs');
const path = require('path');
const config = require('./config');

class RaindropAPI {
  constructor() {
    this.baseURL = 'https://api.raindrop.io/rest/v1';
    this.accessToken = config.accessToken;
    this.refreshToken = config.refreshToken;
    this.client = axios.create({
      baseURL: this.baseURL,
      headers: {
        'Authorization': `Bearer ${this.accessToken}`,
        'Content-Type': 'application/json'
      }
    });
  }

  /**
   * Refresh the access token using refresh token
   */
  async refreshAccessToken() {
    if (!this.refreshToken) {
      throw new Error('No refresh token available');
    }

    try {
      const response = await axios.post('https://raindrop.io/oauth/access_token', {
        grant_type: 'refresh_token',
        refresh_token: this.refreshToken
      });

      this.accessToken = response.data.access_token;
      this.client.defaults.headers['Authorization'] = `Bearer ${this.accessToken}`;
      
      console.log('✅ Access token refreshed successfully');
      return this.accessToken;
    } catch (error) {
      console.error('❌ Failed to refresh access token:', error.response?.data || error.message);
      throw error;
    }
  }

  /**
   * Test the API connection
   */
  async testConnection() {
    try {
      const response = await this.client.get('/user');
      console.log('✅ API connection successful');
      return response.data;
    } catch (error) {
      if (error.response?.status === 401 && this.refreshToken) {
        console.log('🔄 Access token expired, attempting refresh...');
        await this.refreshAccessToken();
        return this.testConnection();
      }
      throw error;
    }
  }

  /**
   * Get user's collections
   */
  async getCollections() {
    try {
      const response = await this.client.get('/collections');
      return response.data;
    } catch (error) {
      if (error.response?.status === 401 && this.refreshToken) {
        await this.refreshAccessToken();
        return this.getCollections();
      }
      throw error;
    }
  }

  /**
   * Upload a file to Raindrop.io
   */
  async uploadFile(filePath, options = {}) {
    try {
      const filename = path.basename(filePath);
      const fileStream = fs.createReadStream(filePath);
      const form = new FormData();
      
      // Add file to form
      form.append('file', fileStream, {
        filename: filename,
        contentType: this.getMimeType(filePath)
      });

      // Add optional parameters
      if (config.collectionId) {
        form.append('collection', config.collectionId);
      }
      
      if (config.tags && config.tags.length > 0) {
        form.append('tags', config.tags.join(','));
      }

      // Add excerpt with timestamp
      const excerpt = options.excerpt || `Screenshot taken on ${new Date().toLocaleDateString()}`;
      form.append('excerpt', excerpt);

      // Add title (filename without extension)
      const title = options.title || path.parse(filename).name;
      form.append('title', title);

      console.log(`📤 Uploading ${filename} to Raindrop.io...`);

      const response = await this.client.put('/raindrop/file', form, {
        headers: {
          ...form.getHeaders(),
          'Authorization': `Bearer ${this.accessToken}`
        },
        maxContentLength: Infinity,
        maxBodyLength: Infinity
      });

      console.log(`✅ Successfully uploaded ${filename}`);
      return response.data;

    } catch (error) {
      console.error(`❌ Failed to upload ${path.basename(filePath)}:`, error.response?.data || error.message);
      
      // Handle specific error cases
      if (error.response?.data) {
        const errorData = error.response.data;
        if (errorData.error === 'file_invalid') {
          throw new Error('File is invalid or corrupted');
        } else if (errorData.error === 'file_size_limit') {
          throw new Error('File size exceeds limit');
        } else if (errorData.error === 'no file') {
          throw new Error('No file was provided');
        }
      }

      // Try to refresh token if unauthorized
      if (error.response?.status === 401 && this.refreshToken) {
        console.log('🔄 Access token expired, attempting refresh...');
        await this.refreshAccessToken();
        return this.uploadFile(filePath, options);
      }

      throw error;
    }
  }

  /**
   * Get MIME type based on file extension
   */
  getMimeType(filePath) {
    const ext = path.extname(filePath).toLowerCase();
    const mimeTypes = {
      '.png': 'image/png',
      '.jpg': 'image/jpeg',
      '.jpeg': 'image/jpeg',
      '.gif': 'image/gif',
      '.bmp': 'image/bmp',
      '.webp': 'image/webp'
    };
    return mimeTypes[ext] || 'application/octet-stream';
  }

  /**
   * Create a standard raindrop with a file link (stretch goal)
   */
  async createRaindropFromFile(fileResponse, options = {}) {
    try {
      const raindropData = {
        link: fileResponse.link,
        title: options.title || fileResponse.title,
        excerpt: options.excerpt || fileResponse.excerpt,
        tags: options.tags || config.tags,
        collection: {
          $id: config.collectionId || fileResponse.collection
        }
      };

      const response = await this.client.post('/raindrop', raindropData);
      console.log('✅ Created raindrop with file link');
      return response.data;
    } catch (error) {
      console.error('❌ Failed to create raindrop:', error.response?.data || error.message);
      throw error;
    }
  }

  /**
   * Check if a file has already been uploaded (basic deduplication)
   */
  async checkDuplicate(filename) {
    try {
      const response = await this.client.get('/raindrops/0', {
        params: {
          search: filename,
          type: 'file'
        }
      });

      const duplicates = response.data.items.filter(item => 
        item.title === filename || item.title === path.parse(filename).name
      );

      return duplicates.length > 0;
    } catch (error) {
      console.warn('⚠️ Could not check for duplicates:', error.message);
      return false;
    }
  }

  /**
   * Get user quota information
   */
  async getUserQuota() {
    try {
      const response = await this.client.get('/user');
      const user = response.data.user;
      
      if (user.files) {
        const usedBytes = user.files.used || 0;
        const totalBytes = user.files.size || (user.pro ? 10000000000 : 104857600); // 10GB for pro, 100MB for free
        const remainingBytes = totalBytes - usedBytes;
        
        return {
          used: usedBytes,
          total: totalBytes,
          remaining: remainingBytes,
          usedMB: Math.round(usedBytes / (1024 * 1024) * 100) / 100,
          totalMB: Math.round(totalBytes / (1024 * 1024) * 100) / 100,
          remainingMB: Math.round(remainingBytes / (1024 * 1024) * 100) / 100,
          usedPercent: Math.round((usedBytes / totalBytes) * 100),
          isPro: user.pro || false
        };
      }
      
      return null;
    } catch (error) {
      console.error('❌ Failed to get user quota:', error.response?.data || error.message);
      if (error.response?.status === 401 && this.refreshToken) {
        await this.refreshAccessToken();
        return this.getUserQuota();
      }
      throw error;
    }
  }
}

module.exports = RaindropAPI; 