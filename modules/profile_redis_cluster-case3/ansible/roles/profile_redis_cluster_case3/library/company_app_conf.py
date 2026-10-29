#!/usr/bin/python
# -*- coding: utf-8 -*-

# Copyright: (c) 2024, Platform Team
# Apache-2.0 License

"""
Ansible module: company_app_conf

Manages !key=value entries in the proprietary CompanyApp settings file format.

Replaces: myFormatType1 / myFormatProvider1 Puppet custom type and provider.

The CompanyApp settings file uses a proprietary line-based format:
  - Lines starting with '#' are comments (preserved as-is)
  - Blank lines are preserved as-is
  - Valid entries have the form: !key=value
  - Unrecognized lines are preserved as-is
"""

from __future__ import absolute_import, division, print_function
__metaclass__ = type

DOCUMENTATION = r'''
---
module: company_app_conf
short_description: Manage !key=value entries in a CompanyApp settings file
description:
  - Manages entries in the proprietary CompanyApp settings file format.
  - Each entry is a line of the form C(!key=value).
  - Comments (C(#)), blank lines, and unrecognized lines are preserved exactly.
  - Idempotent: only modifies the file when the content actually changes.
options:
  file:
    description:
      - Absolute path to the CompanyApp settings file.
    type: str
    required: true
  entry:
    description:
      - The key name to manage (matched against C(!key=value) lines).
    type: str
    required: true
  value:
    description:
      - The value to set for the entry. Required when I(state=present).
    type: str
    required: false
  state:
    description:
      - Whether the entry should be C(present) or C(absent).
    type: str
    choices: [ present, absent ]
    default: present
author:
  - Platform Team
'''

EXAMPLES = r'''
- name: Set app-mode entry
  company_app_conf:
    file: /etc/company/app.conf
    entry: app-mode
    value: cluster
    state: present

- name: Set health-port entry
  company_app_conf:
    file: /etc/company/app.conf
    entry: health-port
    value: "8080"
    state: present

- name: Remove an entry
  company_app_conf:
    file: /etc/company/app.conf
    entry: old-setting
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
    """Parse a !key=value line. Returns (key, value) or (None, None)."""
    if not line.startswith('!'):
        return None, None
    rest = line[1:]
    if '=' not in rest:
        return None, None
    key, sep, val = rest.partition('=')
    return key.strip(), val.strip()


def read_lines(filepath):
    """Read file lines, returning empty list if file does not exist."""
    if not os.path.exists(filepath):
        return []
    try:
        with open(filepath, 'r') as fh:
            return [line.rstrip('\n') for line in fh.readlines()]
    except IOError as exc:
        raise IOError("Cannot read {0}: {1}".format(filepath, exc))


def write_lines(filepath, lines, module):
    """Write lines to file, creating parent directories if needed."""
    parent = os.path.dirname(filepath)
    if parent and not os.path.exists(parent):
        try:
            os.makedirs(parent)
        except OSError as exc:
            module.fail_json(msg="Cannot create directory {0}: {1}".format(parent, exc))
    try:
        with open(filepath, 'w') as fh:
            for line in lines:
                fh.write(line + '\n')
    except IOError as exc:
        module.fail_json(msg="Cannot write {0}: {1}".format(filepath, exc))


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

    filepath = module.params['file']
    entry = module.params['entry']
    value = module.params['value']
    state = module.params['state']

    if state == 'present' and value is None:
        module.fail_json(msg="'value' is required when state=present")

    if not entry:
        module.fail_json(msg="'entry' must not be empty")

    try:
        existing_lines = read_lines(filepath)
    except IOError as exc:
        module.fail_json(msg=str(exc))

    # Build new lines list
    if state == 'present':
        # Check if entry already exists with correct value
        for line in existing_lines:
            k, v = parse_entry(line)
            if k == entry and v == str(value):
                # Already correct — no change needed
                module.exit_json(changed=False, msg="Entry '{0}' already set to '{1}'".format(entry, value))

        # Remove all existing lines for this key, then append the new entry
        new_lines = [line for line in existing_lines if parse_entry(line)[0] != entry]
        new_lines.append("!{0}={1}".format(entry, value))
        changed = True
        msg = "Entry '{0}' set to '{1}'".format(entry, value)

    else:  # state == 'absent'
        new_lines = [line for line in existing_lines if parse_entry(line)[0] != entry]
        if new_lines == existing_lines:
            module.exit_json(changed=False, msg="Entry '{0}' not present, nothing to remove".format(entry))
        changed = True
        msg = "Entry '{0}' removed".format(entry)

    if module.check_mode:
        module.exit_json(changed=changed, msg=msg)

    write_lines(filepath, new_lines, module)
    module.exit_json(changed=changed, msg=msg)


def main():
    run_module()


if __name__ == '__main__':
    main()
