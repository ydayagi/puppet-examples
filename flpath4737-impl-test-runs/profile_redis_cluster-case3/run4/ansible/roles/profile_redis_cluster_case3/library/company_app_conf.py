#!/usr/bin/python
# -*- coding: utf-8 -*-

# Copyright: (c) 2024, x2a
# Apache-2.0 License

from __future__ import absolute_import, division, print_function
__metaclass__ = type

DOCUMENTATION = r'''
---
module: company_app_conf
short_description: Manage entries in a proprietary CompanyApp settings file
description:
  - Manages C(!key=value) entries in a proprietary CompanyApp settings file.
  - Lines starting with C(!) are treated as entries; all other lines (comments,
    blank lines, unrecognised content) are preserved verbatim.
  - When I(state=present) the module ensures the exact line C(!entry=value)
    exists; when I(state=absent) it removes any line whose key matches I(entry).
  - The file is rewritten in-place only when a change is required (idempotent).
options:
  file:
    description:
      - Absolute path to the CompanyApp settings file.
    type: str
    required: true
  entry:
    description:
      - The key name to manage (the part between C(!) and C(=)).
    type: str
    required: true
  value:
    description:
      - The desired value for the entry.
      - Required when I(state=present).
    type: str
    required: false
  state:
    description:
      - Whether the entry should be C(present) or C(absent).
    type: str
    choices: [ present, absent ]
    default: present
author:
  - x2a migration
'''

EXAMPLES = r'''
- name: Set app-mode in /etc/company/app.conf
  company_app_conf:
    file: /etc/company/app.conf
    entry: app-mode
    value: cluster
    state: present

- name: Remove health-port from /etc/company/app.conf
  company_app_conf:
    file: /etc/company/app.conf
    entry: health-port
    state: absent
'''

RETURN = r'''
changed:
  description: Whether the file was modified.
  type: bool
  returned: always
msg:
  description: Human-readable description of what happened.
  type: str
  returned: always
'''

import os
import traceback

from ansible.module_utils.basic import AnsibleModule


def parse_entry(line):
    """Return (key, value) for a !key=value line, or (None, None) otherwise."""
    if not line.startswith('!'):
        return None, None
    rest = line[1:]
    if '=' not in rest:
        return None, None
    key, _, val = rest.partition('=')
    return key.strip(), val.strip()


def read_lines(path):
    """Read file lines (chomped). Returns [] if file does not exist."""
    if not os.path.exists(path):
        return None  # distinguish "missing" from "empty"
    with open(path, 'r') as fh:
        return [l.rstrip('\n') for l in fh.readlines()]


def write_lines(path, lines, module):
    """Write lines to path, creating parent directories as needed."""
    parent = os.path.dirname(path)
    if parent and not os.path.exists(parent):
        try:
            os.makedirs(parent)
        except OSError as exc:
            module.fail_json(msg="Cannot create directory {0}: {1}".format(parent, str(exc)))
    try:
        with open(path, 'w') as fh:
            fh.write('\n'.join(lines))
            if lines:
                fh.write('\n')
    except IOError as exc:
        module.fail_json(msg="Cannot write to {0}: {1}".format(path, str(exc)))


def run_module():
    module_args = dict(
        file=dict(type='str', required=True),
        entry=dict(type='str', required=True),
        value=dict(type='str', required=False, default=None),
        state=dict(type='str', default='present', choices=['present', 'absent']),
    )

    module = AnsibleModule(
        argument_spec=module_args,
        supports_check_mode=True,
    )

    conf_file = module.params['file']
    entry = module.params['entry']
    value = module.params['value']
    state = module.params['state']

    if not entry:
        module.fail_json(msg="entry must not be empty")

    if state == 'present' and value is None:
        module.fail_json(msg="value is required when state=present")

    existing_lines = read_lines(conf_file)
    file_missing = existing_lines is None
    if file_missing:
        existing_lines = []

    # --- state=absent ---
    if state == 'absent':
        if file_missing:
            module.exit_json(changed=False, msg="File does not exist; nothing to remove.")
        new_lines = [l for l in existing_lines if parse_entry(l)[0] != entry]
        if new_lines == existing_lines:
            module.exit_json(changed=False, msg="Entry '{0}' not found; no change.".format(entry))
        if not module.check_mode:
            write_lines(conf_file, new_lines, module)
        module.exit_json(changed=True, msg="Removed entry '{0}' from {1}.".format(entry, conf_file))

    # --- state=present ---
    desired_line = "!{0}={1}".format(entry, value)

    # Check if exact line already exists
    if desired_line in existing_lines:
        module.exit_json(changed=False, msg="Entry '{0}={1}' already present; no change.".format(entry, value))

    # Remove all lines matching this key, then append desired line
    new_lines = [l for l in existing_lines if parse_entry(l)[0] != entry]
    new_lines.append(desired_line)

    if not module.check_mode:
        write_lines(conf_file, new_lines, module)

    module.exit_json(
        changed=True,
        msg="Set entry '{0}={1}' in {2}.".format(entry, value, conf_file),
    )


def main():
    run_module()


if __name__ == '__main__':
    main()
