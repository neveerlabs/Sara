import 'package:path/path.dart' as path;

String attachmentMimeType(String filePath) {
  return switch (path.extension(filePath).toLowerCase()) {
    '.jpg' || '.jpeg' => 'image/jpeg',
    '.png' => 'image/png',
    '.webp' => 'image/webp',
    '.heic' => 'image/heic',
    '.heif' => 'image/heif',
    '.gif' => 'image/gif',
    '.tif' || '.tiff' => 'image/tiff',
    '.mp4' => 'video/mp4',
    '.mpeg' || '.mpg' => 'video/mpeg',
    '.mov' => 'video/quicktime',
    '.webm' => 'video/webm',
    '.3gp' => 'video/3gpp',
    '.pdf' => 'application/pdf',
    '.txt' || '.log' => 'text/plain',
    '.csv' => 'text/csv',
    '.json' => 'application/json',
    '.html' || '.htm' => 'text/html',
    '.xml' => 'application/xml',
    '.md' || '.markdown' => 'text/markdown',
    '.py' => 'text/x-python',
    '.js' || '.mjs' || '.cjs' => 'text/javascript',
    '.ts' || '.tsx' => 'text/typescript',
    '.jsx' => 'text/javascript',
    '.css' => 'text/css',
    '.yaml' || '.yml' => 'application/yaml',
    '.toml' => 'application/toml',
    '.sql' => 'application/sql',
    '.sh' || '.bash' => 'application/x-sh',
    '.c' || '.h' => 'text/x-c',
    '.cc' || '.cpp' || '.hpp' => 'text/x-c++',
    '.java' => 'text/x-java',
    '.go' => 'text/x-go',
    '.rs' => 'text/x-rust',
    '.zip' => 'application/zip',
    '.gz' => 'application/gzip',
    '.tar' => 'application/x-tar',
    '.7z' => 'application/x-7z-compressed',
    '.doc' => 'application/msword',
    '.docx' =>
      'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
    '.xls' => 'application/vnd.ms-excel',
    '.xlsx' =>
      'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
    '.ppt' => 'application/vnd.ms-powerpoint',
    '.pptx' =>
      'application/vnd.openxmlformats-officedocument.presentationml.presentation',
    '.mp3' => 'audio/mpeg',
    '.wav' => 'audio/wav',
    '.ogg' => 'audio/ogg',
    '.flac' => 'audio/flac',
    '.aac' => 'audio/aac',
    '.m4a' => 'audio/mp4',
    '.woff' => 'font/woff',
    '.woff2' => 'font/woff2',
    '.ttf' => 'font/ttf',
    '.otf' => 'font/otf',
    _ => 'application/octet-stream',
  };
}

bool isSensitiveAttachmentPath(String filePath) {
  final fileName = path.basename(filePath).toLowerCase();
  if (RegExp(r'^\.env(?:$|[._-])').hasMatch(fileName) || fileName == '.envrc') {
    return true;
  }
  if (const {
    '.npmrc',
    '.pypirc',
    '.netrc',
    '.git-credentials',
    'credentials',
    'credentials.json',
    'secrets.json',
    'service-account.json',
  }.contains(fileName)) {
    return true;
  }
  if (RegExp(r'(^|[._-])(secret|secrets|credential|credentials)([._-]|$)')
      .hasMatch(fileName)) {
    return true;
  }
  if (RegExp(r'^id_(rsa|ed25519|ecdsa|dsa)(?:$|\.)').hasMatch(fileName) &&
      !fileName.endsWith('.pub')) {
    return true;
  }
  return const {
    '.pem',
    '.key',
    '.p12',
    '.pfx',
    '.p7b',
    '.p7c',
    '.jks',
    '.keystore',
    '.ppk',
  }.contains(path.extension(fileName));
}
