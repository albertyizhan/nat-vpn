"""Isolated manager flows. Service/platform stubs never change the host system.

Run: python3 -m unittest discover -s tests -v
Fixtures are retained in the system temporary directory for inspection.
"""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

SOURCE = Path(__file__).resolve().parents[1] / 'xray-manager.sh'


class ManagerFlows(unittest.TestCase):
    def setUp(self):
        self.root = Path(tempfile.mkdtemp(prefix='xray-manager-test-'))
        self.config = self.root / 'config.json'
        self.state = self.root / 'manager-state.json'
        inbound = {'tag': 'Alpha', 'protocol': 'shadowsocks', 'port': 8388,
                   'settings': {'method': 'aes-128-gcm', 'password': 'fixture-only', 'network': 'tcp'}}
        paused = dict(inbound, tag='Beta', port=8389)
        self.config.write_text(json.dumps({'inbounds': [inbound], 'outbounds': []}))
        self.state.write_text(json.dumps({'nodes': {
            'Alpha': {'inbound': dict(inbound, port=9999), 'disabled': True,
                      'public_host': 'example.com', 'public_port': 18388},
            'Beta': {'inbound': paused, 'disabled': True, 'disabled_reason': 'monthly_quota',
                     'quota_gib': 10, 'reset_day': 31}}}))
        self.binary = self.root / 'xray'
        self.binary.write_text('#!/bin/sh\n[ "${TEST_INVALID:-0}" != 1 ]\n')
        self.binary.chmod(0o700)
        diagnostic = self.root / 'rc-service'
        diagnostic.write_text('#!/bin/sh\necho fixture-service-diagnosis\n')
        diagnostic.chmod(0o700)
        self.harness = self.root / 'manager.sh'
        source = SOURCE.read_text()
        self.assertTrue(source.endswith('main "$@"\n'))
        # Exercise the actual entry point and subprocess menus, replacing only
        # Linux/root checks and service calls unavailable on the development Mac.
        self.harness.write_text(source.removesuffix('main "$@"\n') + '''
id() { echo 0; }
detect_platform() { INIT=openrc; }
trusted_path() { :; }
service_action() {
  local n
  if [ "$2" = restart ]; then
    n=0
    [ ! -r "$XRAY_DIR/restarts" ] || n="$(cat "$XRAY_DIR/restarts")"
    n=$((n+1)); echo "$n" > "$XRAY_DIR/restarts"
    case "${TEST_SERVICE:-ok}:$n" in fail:*|recover:1) return 1 ;; esac
  fi
  if [ "$2" = status ] && [ "${TEST_SERVICE:-ok}" = inactive ]; then return 1; fi
  return 0
}
main "$@"
''')
        self.env = dict(os.environ, PATH=str(self.root) + os.pathsep + os.environ['PATH'], XRAY_DIR=str(self.root), XRAY_BIN=str(self.binary),
                        CONFIG=str(self.config), STATE=str(self.state), LOG_DIR=str(self.root / 'logs'))

    def run_manager(self, args=(), text='', **env):
        result = subprocess.run(['dash', str(self.harness), *args], input=text,
                                text=True, capture_output=True, timeout=10,
                                env=dict(self.env, **env))
        self.assertFalse((self.root / '.manager.lock').exists(), result.stderr)
        return result, result.stdout + result.stderr

    def test_menu_number_name_and_status(self):
        result, output = self.run_manager(text='1\n1\n0\n1\nBeta\n0\n0\n')
        self.assertEqual(result.returncode, 0, output)
        self.assertIn('1. Alpha  [shadowsocks] 内部端口=8388  启用', output)
        self.assertIn('客户端地址: example.com', output)
        self.assertIn('停用原因: 月流量超限', output)
        self.assertIn('10. 启用节点', output)
        self.assertIn('11. 停用节点', output)
        self.assertNotIn('fixture-only', output)

    def test_edit_cancel_zero_and_saved_result(self):
        before = self.state.read_text()
        result, output = self.run_manager(['--action', 'edit', 'Alpha'], '2\n\n')
        self.assertEqual(result.returncode, 0, output)
        self.assertIn('已取消', output)
        self.assertEqual(self.state.read_text(), before)
        result, output = self.run_manager(['--action', 'max', 'Alpha'], '0\n')
        self.assertEqual(result.returncode, 0, output)
        self.assertEqual(json.loads(self.state.read_text())['nodes']['Alpha']['max_connections'], 0)
        result, output = self.run_manager(['--action', 'edit', 'Alpha'], '2\n65535\n')
        self.assertEqual(result.returncode, 0, output)
        self.assertIn('外部端口已更新为 65535', output)
        self.assertEqual(json.loads(self.state.read_text())['nodes']['Alpha']['public_port'], 65535)

    def test_rename_returns_to_new_node_and_disable(self):
        result, output = self.run_manager(text='1\n1\n9\nGamma\n11\n0\n0\n')
        self.assertEqual(result.returncode, 0, output)
        self.assertIn('节点: Gamma', output)
        self.assertIn('节点 Gamma 已停用', output)
        self.assertEqual(json.loads(self.config.read_text())['inbounds'], [])
        self.assertTrue(json.loads(self.state.read_text())['nodes']['Gamma']['disabled'])

    def test_validation_failure_and_service_recovery(self):
        for settings, expected in [({'TEST_INVALID': '1'}, '配置检查失败，未应用'),
                                   ({'TEST_SERVICE': 'recover'}, '服务已恢复运行'),
                                   ({'TEST_SERVICE': 'fail'}, '服务仍未恢复运行'),
                                   ({'TEST_SERVICE': 'inactive'}, '服务仍未恢复运行')]:
            with self.subTest(settings=settings):
                before = self.config.read_text(), self.state.read_text()
                counter = self.root / 'restarts'
                counter.write_text('0')
                result, output = self.run_manager(['--action', 'disable', 'Alpha'], **settings)
                self.assertNotEqual(result.returncode, 0, output)
                self.assertIn(expected, output)
                self.assertEqual((self.config.read_text(), self.state.read_text()), before)

    def test_invalid_number_and_bad_config_keep_menu(self):
        result, output = self.run_manager(text='1\n999999999\n2\n0\n', TEST_INVALID='1')
        self.assertEqual(result.returncode, 0, output)
        self.assertIn('编号不存在', output)
        self.assertIn('当前配置检查失败', output)


if __name__ == '__main__':
    unittest.main()
