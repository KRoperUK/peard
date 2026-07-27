/** @type {import('@bacons/apple-targets').Config} */
module.exports = {
  type: "widget",
  name: "PearWidget",
  entitlements: {
    // Must match the App Group id used in app.json and PearSharedModule.swift.
    "com.apple.security.application-groups": ["group.com.peard.app"],
  },
};

