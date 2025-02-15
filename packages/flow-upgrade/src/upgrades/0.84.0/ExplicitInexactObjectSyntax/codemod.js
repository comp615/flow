/**
 * Copyright (c) Facebook, Inc. and its affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *
 * @format
 * @flow
 */

'use strict';

module.exports = (j: any, root: any): string => {
  root
    .find(j.ObjectTypeAnnotation, {inexact: false, exact: false})
    .forEach(path => {
      path.node.inexact = true;
    });
  return root.toSource({tabWidth: 2});
};
