/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * SystemAdministration (private): apps link it and import nothing from it (ColorSync
 * Utility does), so Finch's is an empty image at Apple's path and version, there for
 * those apps to load. What it provides on macOS (administering users and groups through
 * authorization) comes as an app needs it.
 */
const double SystemAdministrationVersionNumber = 1.0;
