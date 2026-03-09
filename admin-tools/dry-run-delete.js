#!/usr/bin/env node
const { runCleanup } = require('./lib/cleanup-core');

runCleanup({ argv: process.argv.slice(2), forceConfirmMode: false })
  .then(() => process.exit(0))
  .catch((error) => {
    console.error('\n[DRY-RUN FAILED]', error.message || error);
    process.exit(1);
  });
