#!/usr/bin/env node

const { exec } = require('child_process');
const fs = require('fs');
const path = require('path');
const os = require('os');

class DaemonManager {
  constructor() {
    this.plistPath = path.join(__dirname, 'com.raindrop.screenshot.automation.plist');
    this.launchAgentPath = path.join(os.homedir(), 'Library', 'LaunchAgents', 'com.raindrop.screenshot.automation.plist');
    this.logPath = path.join(os.homedir(), 'Library', 'Logs', 'RaindropScreenshot.log');
    this.errorLogPath = path.join(os.homedir(), 'Library', 'Logs', 'RaindropScreenshot.error.log');
  }

  async run() {
    const command = process.argv[2];
    
    switch (command) {
      case 'install':
        await this.install();
        break;
      case 'uninstall':
        await this.uninstall();
        break;
      case 'start':
        await this.start();
        break;
      case 'stop':
        await this.stop();
        break;
      case 'restart':
        await this.restart();
        break;
      case 'status':
        await this.status();
        break;
      case 'logs':
        await this.logs();
        break;
      case 'errors':
        await this.errors();
        break;
      default:
        this.showUsage();
    }
  }

  async install() {
    try {
      console.log('🔧 Installing Raindrop Screenshot Automation daemon...');
      
      // Check if .env file exists
      if (!fs.existsSync('.env')) {
        console.log('❌ .env file not found. Please run setup first:');
        console.log('   npm run setup');
        return;
      }
      
      // Ensure LaunchAgents directory exists
      const launchAgentsDir = path.dirname(this.launchAgentPath);
      if (!fs.existsSync(launchAgentsDir)) {
        fs.mkdirSync(launchAgentsDir, { recursive: true });
        console.log('📁 Created LaunchAgents directory');
      }
      
      // Ensure log directory exists
      const logDir = path.dirname(this.logPath);
      if (!fs.existsSync(logDir)) {
        fs.mkdirSync(logDir, { recursive: true });
        console.log('📁 Created Logs directory');
      }
      
      // Copy plist to LaunchAgents folder
      fs.copyFileSync(this.plistPath, this.launchAgentPath);
      console.log('✅ Daemon plist copied to LaunchAgents');
      
      // Load the daemon
      await this.execCommand(`launchctl load ${this.launchAgentPath}`);
      console.log('✅ Daemon loaded and will start on login');
      
      // Start immediately
      await this.start();
      
      console.log('\n🎉 Daemon installed successfully!');
      console.log('📋 Management commands:');
      console.log('   node daemon-manager.js status   - Check if running');
      console.log('   node daemon-manager.js logs     - View logs');
      console.log('   node daemon-manager.js stop     - Stop daemon');
      console.log('   node daemon-manager.js start    - Start daemon');
      
    } catch (error) {
      console.error('❌ Failed to install daemon:', error.message);
      console.log('\n💡 Troubleshooting:');
      console.log('   - Make sure you have run "npm run setup" first');
      console.log('   - Check that the .env file exists and is configured');
      console.log('   - Verify Node.js is installed in /usr/local/bin/node');
    }
  }

  async uninstall() {
    try {
      console.log('🗑️  Uninstalling daemon...');
      
      // Stop the daemon first
      await this.stop();
      
      // Unload the daemon
      try {
        await this.execCommand(`launchctl unload ${this.launchAgentPath}`);
        console.log('✅ Daemon unloaded');
      } catch (error) {
        console.log('⚠️  Daemon was not loaded');
      }
      
      // Remove plist file
      if (fs.existsSync(this.launchAgentPath)) {
        fs.unlinkSync(this.launchAgentPath);
        console.log('✅ Daemon plist removed');
      }
      
      console.log('✅ Daemon uninstalled successfully');
      
    } catch (error) {
      console.error('❌ Failed to uninstall daemon:', error.message);
    }
  }

  async start() {
    try {
      await this.execCommand('launchctl start com.raindrop.screenshot.automation');
      console.log('✅ Daemon started');
      
      // Wait a moment and check if it's actually running
      await new Promise(resolve => setTimeout(resolve, 2000));
      await this.status();
      
    } catch (error) {
      console.error('❌ Failed to start daemon:', error.message);
      console.log('\n💡 Try checking the logs:');
      console.log('   node daemon-manager.js logs');
      console.log('   node daemon-manager.js errors');
    }
  }

  async stop() {
    try {
      await this.execCommand('launchctl stop com.raindrop.screenshot.automation');
      console.log('✅ Daemon stopped');
    } catch (error) {
      console.error('❌ Failed to stop daemon:', error.message);
    }
  }

  async restart() {
    console.log('🔄 Restarting daemon...');
    await this.stop();
    await new Promise(resolve => setTimeout(resolve, 2000));
    await this.start();
  }

  async status() {
    try {
      const result = await this.execCommand('launchctl list | grep com.raindrop.screenshot.automation');
      if (result.trim()) {
        console.log('✅ Daemon is running');
        const parts = result.trim().split('\t');
        if (parts.length >= 3) {
          const pid = parts[0];
          const exitCode = parts[1];
          const label = parts[2];
          console.log(`   PID: ${pid}`);
          console.log(`   Exit Code: ${exitCode}`);
          console.log(`   Label: ${label}`);
        }
      } else {
        console.log('❌ Daemon is not running');
      }
    } catch (error) {
      console.log('❌ Daemon is not running');
    }
  }

  async logs() {
    try {
      console.log('📋 Recent logs:');
      console.log('═'.repeat(50));
      
      if (fs.existsSync(this.logPath)) {
        const logs = fs.readFileSync(this.logPath, 'utf8');
        const recentLogs = logs.split('\n').slice(-50).join('\n');
        console.log(recentLogs);
      } else {
        console.log('📋 No logs found at:', this.logPath);
      }
      
      console.log('═'.repeat(50));
      console.log(`📂 Full log file: ${this.logPath}`);
      
    } catch (error) {
      console.error('❌ Failed to read logs:', error.message);
    }
  }

  async errors() {
    try {
      console.log('🚨 Recent errors:');
      console.log('═'.repeat(50));
      
      if (fs.existsSync(this.errorLogPath)) {
        const errors = fs.readFileSync(this.errorLogPath, 'utf8');
        const recentErrors = errors.split('\n').slice(-50).join('\n');
        console.log(recentErrors);
      } else {
        console.log('🚨 No errors found at:', this.errorLogPath);
      }
      
      console.log('═'.repeat(50));
      console.log(`📂 Full error log: ${this.errorLogPath}`);
      
    } catch (error) {
      console.error('❌ Failed to read error logs:', error.message);
    }
  }

  execCommand(command) {
    return new Promise((resolve, reject) => {
      exec(command, (error, stdout, stderr) => {
        if (error) {
          reject(error);
        } else {
          resolve(stdout);
        }
      });
    });
  }

  showUsage() {
    console.log(`
🚀 Raindrop Screenshot Automation Daemon Manager

Usage: node daemon-manager.js <command>

Commands:
  install   - Install and start the daemon (runs on login)
  uninstall - Stop and remove the daemon
  start     - Start the daemon
  stop      - Stop the daemon
  restart   - Restart the daemon
  status    - Check daemon status
  logs      - View recent logs
  errors    - View recent errors

Examples:
  node daemon-manager.js install
  node daemon-manager.js status
  node daemon-manager.js logs

Setup:
  1. First run: npm run setup
  2. Then run: node daemon-manager.js install
  3. The daemon will start automatically on login

Troubleshooting:
  - Check logs: node daemon-manager.js logs
  - Check errors: node daemon-manager.js errors
  - Restart: node daemon-manager.js restart
    `);
  }
}

if (require.main === module) {
  const manager = new DaemonManager();
  manager.run();
}

module.exports = DaemonManager; 