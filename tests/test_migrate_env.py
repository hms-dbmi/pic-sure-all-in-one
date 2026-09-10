"""Run the environment migrator against synthetic configs; no Docker or database calls."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[1]
DEFAULT_URL = 'jdbc:mysql://picsure-db:3306/picsure?useUnicode=true&characterEncoding=UTF-8&autoReconnect=true&autoReconnectForPools=true&serverTimezone=UTC'


class DatabaseMigrationTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.config = Path(self.temp.name)
        self.write('wildfly/standalone.xml', '''<server>
<datasource pool-name="PicsureDS">
<connection-url>jdbc:mysql://picsure-db:3306/picsure?useUnicode=true&amp;characterEncoding=UTF-8</connection-url>
<security><user-name>picsure</user-name>
<password>synthetic-password</password></security>
</datasource>
<simple name="java:global/token_introspection_token" value="synthetic-token"/>
</server>''')

    def write(self, name, content):
        path = self.config / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content)

    def run_migration(self):
        env = {k: v for k, v in os.environ.items()
               if k not in ('HPDS_OPTS', 'PSAMA_OPTS', 'MIGRATION_TEMPLATE_DIR')}
        env['DOCKER_CONFIG_DIR'] = str(self.config)
        return subprocess.run(['bash', str(REPO / 'initial-configuration/migrate-env.sh')],
                              env=env, capture_output=True, text=True)

    def operations(self):
        return dict(line.split('=', 1) for line in
                    (self.config / 'operations/operations.env').read_text().splitlines()
                    if '=' in line and not line.startswith('#'))

    def assert_success(self):
        result = self.run_migration()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def test_local_connection_is_explicit_and_xml_ampersand_is_decoded(self):
        self.assert_success()
        values = self.operations()
        self.assertEqual(values.get('SPRING_DATASOURCE_URL'),
                         'jdbc:mysql://picsure-db:3306/picsure?useUnicode=true&characterEncoding=UTF-8')
        self.assertEqual(values.get('SPRING_DATASOURCE_USERNAME'), 'picsure')
        self.assertEqual(values['SPRING_DATASOURCE_PASSWORD'], 'synthetic-password')

    def test_remote_connection_and_custom_username_are_preserved(self):
        path = self.config / 'wildfly/standalone.xml'
        path.write_text(path.read_text().replace('picsure-db:3306', 'database.example.invalid:3307')
                        .replace('<user-name>picsure', '<user-name>custom_user'))
        self.assert_success()
        self.assertEqual(self.operations().get('SPRING_DATASOURCE_URL'),
                         'jdbc:mysql://database.example.invalid:3307/picsure?useUnicode=true&characterEncoding=UTF-8')
        self.assertEqual(self.operations().get('SPRING_DATASOURCE_USERNAME'), 'custom_user')

    def test_incomplete_operations_file_keeps_explicit_connection_over_legacy_xml(self):
        self.write('operations/operations.env',
                   'SPRING_DATASOURCE_URL=jdbc:mysql://override.example.invalid:3308/picsure\n'
                   'SPRING_DATASOURCE_USERNAME=override_user\n'
                   'SPRING_DATASOURCE_PASSWORD=synthetic-override\n')
        self.assert_success()
        self.assertEqual(self.operations().get('SPRING_DATASOURCE_URL'),
                         'jdbc:mysql://override.example.invalid:3308/picsure')
        self.assertEqual(self.operations().get('SPRING_DATASOURCE_USERNAME'), 'override_user')
        self.assertEqual(self.operations()['SPRING_DATASOURCE_PASSWORD'], 'synthetic-override')

    def test_rerun_without_legacy_xml_preserves_service_defaults_and_secrets(self):
        self.assert_success()
        original = self.operations()
        path = self.config / 'operations/operations.env'
        path.write_text('\n'.join(line for line in path.read_text().splitlines()
                                  if not line.startswith(('SPRING_DATASOURCE_URL=', 'SPRING_DATASOURCE_USERNAME='))) + '\n')
        (self.config / 'wildfly/standalone.xml').unlink()
        self.assert_success()
        values = self.operations()
        self.assertEqual(values.get('SPRING_DATASOURCE_URL'), DEFAULT_URL)
        self.assertEqual(values.get('SPRING_DATASOURCE_USERNAME'), 'picsure')
        for key in ('SPRING_DATASOURCE_PASSWORD', 'QUERY_SERVICE_INTERNAL_TOKEN'):
            self.assertEqual(values[key], original[key])
        snapshot = path.read_bytes()
        self.assert_success()
        self.assertEqual(path.read_bytes(), snapshot)

    def test_unresolved_legacy_url_fails_before_installing_envs(self):
        path = self.config / 'wildfly/standalone.xml'
        path.write_text(path.read_text().replace('picsure-db:3306', '${env.DB_HOST}:3306'))
        result = self.run_migration()
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.config / 'operations/operations.env').exists())

    def test_missing_legacy_url_does_not_silently_default_to_local(self):
        path = self.config / 'wildfly/standalone.xml'
        path.write_text('\n'.join(line for line in path.read_text().splitlines()
                                  if '<connection-url>' not in line))
        result = self.run_migration()
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.config / 'operations/operations.env').exists())

    def test_embedded_template_placeholder_fails_before_installing_envs(self):
        path = self.config / 'wildfly/standalone.xml'
        path.write_text(path.read_text().replace('picsure-db', '__MYSQL_HOST__'))
        result = self.run_migration()
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.config / 'operations/operations.env').exists())

    def test_missing_username_does_not_read_another_datasource(self):
        path = self.config / 'wildfly/standalone.xml'
        path.write_text(path.read_text().replace('<user-name>picsure</user-name>', '')
                        .replace('</server>', '<datasource pool-name="OtherDS">'
                                 '<user-name>other_user</user-name></datasource></server>'))
        result = self.run_migration()
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.config / 'operations/operations.env').exists())

    def test_backslashes_in_explicit_url_are_not_interpreted_by_awk(self):
        url = r'jdbc:mysql://db.example.invalid/picsure?sessionVariables=sql_mode=ANSI\n'
        self.write('operations/operations.env', 'SPRING_DATASOURCE_URL=' + url + '\n')
        self.assert_success()
        self.assertEqual(self.operations()['SPRING_DATASOURCE_URL'], url)


if __name__ == '__main__':
    unittest.main()
