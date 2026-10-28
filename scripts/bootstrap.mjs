import { copyFile, mkdir } from 'node:fs/promises';
import { constants } from 'node:fs';
const config = new URL('../Config/', import.meta.url);
await mkdir(config, {recursive:true});
try {
  await copyFile(new URL('RemoteRelay.example.xcconfig', config), new URL('RemoteRelay.xcconfig', config), constants.COPYFILE_EXCL);
  console.log('Created empty local configuration. Add your own endpoints and credentials before connecting.');
} catch (error) {
  if (error.code !== 'EEXIST') throw error;
  console.log('Existing local configuration preserved.');
}
