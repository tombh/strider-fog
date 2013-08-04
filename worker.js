var fs = require('fs')
var path = require('path')

var STRIDER_FOG_JSON = "strider-fog.json"

// Read & parse a JSON file
function getJson(filename, cb) {
  fs.readFile(filename, function(err, data) {
    if (err) return cb(err, null)
    try {
      var json = JSON.parse(data)
      cb(null, json)
    } catch(e) {
      cb(e, null)
    }
  })
}

function customCmd(cmd, ctx, cb) {
  getJson(
    path.join(ctx.workingDir, STRIDER_FOG_JSON),
    function(err, json) {
      if (err) {
        ctx.striderMessage("Failed to parse " + STRIDER_FOG_JSON)
        return cb(0)
      }
      // No command found - continue
      if (!json[cmd]) {
        return cb(0)
      }

      runCmd(ctx, cmd, json[cmd], cb);
  })
}

var runCmd = function(ctx, phase, cmd, cb){
  var proxy = "ruby " + __dirname + "/fog_proxy.rb"
  var proxy_cmd = proxy +
    " --jobid " + ctx.jobData.job_id +
    " --dir " + ctx.workingDir +
    " --phase " + phase +
    " --cmd '" + cmd + "'"
  var sh = ctx.shellWrap(proxy_cmd)
  ctx.forkProc(ctx.workingDir, sh.cmd, sh.args, function(exitCode) {
    if (exitCode !== 0) {
      ctx.striderMessage("Custom " + phase + " command `" +
       cmd + "` failed with exit code " + exitCode);
      return cb(exitCode);
    }
    return cb(0);
  });
};

module.exports = function(ctx, cb) {
  ctx.addDetectionRule({
    filename: STRIDER_FOG_JSON,
    language: "fog",
    framework: null,
    exists: true,
    prepare: function(ctx, cb){ customCmd("prepare", ctx, cb) },
    test: function(ctx, cb){ customCmd("test", ctx, cb) },
    cleanup: function(ctx, cb){ runCmd(ctx, "cleanup", "true", cb) },
  })

  console.log("strider-fog extension loaded")
  cb(null, null)
}
