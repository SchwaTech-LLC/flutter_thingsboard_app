/// The servers supported by the MonoHub application.
abstract final class MonoHubInstances {
  static const production = 'https://monohub.schwatech.com';
  static const development = 'https://monohub-dev.schwatech.com';
  static const oracle = 'https://thingsboard-oracle.schwatech.com';
  static const labels = {
    production: 'MonoHub — Production',
    development: 'MonoHub — Development',
    oracle: 'ThingsBoard — Oracle',
  };
}
