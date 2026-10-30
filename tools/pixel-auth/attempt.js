/* ES5 one-shot authentication controller. No credentials or Android identifiers.
 * Caller owns an OS lock and supplies private configuration plus UI adapter.
 * A page-left result must still be followed by the application's readiness gate.
 */
function runAttempt(env, config, request) {
  function done(state, reason) { env.report(state, reason); return {state:state, reason:reason}; }
  function loginPage(s) { return s && s.target === true && s.gesturePage === true && s.accountMatch === true; }
  var wall=env.wallNow();
  if (!request || typeof request.id!=='string' || !/^[a-f0-9-]{16,64}$/.test(request.id) ||
      typeof request.issuedAt!=='number' || typeof request.expiresAt!=='number' ||
      wall<request.issuedAt-5000 || wall>request.expiresAt || !isFinite(request.issuedAt) || !isFinite(request.expiresAt) || request.expiresAt<=request.issuedAt || request.expiresAt-request.issuedAt>45000)
    return done('blocked','REQUEST_INVALID_OR_EXPIRED');
  if(env.guardExists())return done('blocked','PRIOR_ATTEMPT_UNRECONCILED');
  if(!config || typeof config.width!=='number' || typeof config.height!=='number' || !isFinite(config.width) || !isFinite(config.height) || config.width<=0 || config.height<=0 || !Array.isArray(config.points) || config.points.length<2 || config.points.length>9)
    return done('blocked','CONFIG_INVALID');
  for(var i=0;i<config.points.length;i++) {
    var p=config.points[i];
    if(!Array.isArray(p)||p.length!==2||typeof p[0]!=='number'||typeof p[1]!=='number'||
       !isFinite(p[0])||!isFinite(p[1])||p[0]<0||p[1]<0||p[0]>=config.width||p[1]>=config.height)
      return done('blocked','CONFIG_INVALID');
  }
  var until=env.now()+4000, s=env.observe();
  while(!loginPage(s) && env.now()<until) { env.sleep(200);s=env.observe(); }
  if(!loginPage(s))return done('blocked','EXPECTED_LOGIN_PAGE_NOT_VISIBLE');
  if(s.screenOn!==true || s.width!==config.width || s.height!==config.height)
    return done('blocked','SCREEN_NOT_CONFIRMED');
  // Durable marker precedes input; interruption must never make it replayable.
  env.writeGuard(request.id);
  env.report('attempting','INPUT_INTENT_PERSISTED');
  s=env.observe();
  if(!loginPage(s)||s.screenOn!==true||s.width!==config.width||s.height!==config.height)
    return done('blocked','CONTEXT_CHANGED_BEFORE_INPUT');
  try { env.input(config.points); }
  catch(error) { return done('interrupted','INPUT_EXCEPTION_NO_RETRY'); }
  until=env.now()+12000;
  var stableSince=null;
  while(env.now()<until) {
    s=env.observe();
    if(s && s.target===true && s.screenOn===true && s.gesturePage===false && s.knownPostLoginActivity===true) {
      if(stableSince===null)stableSince=env.now();
      if(env.now()-stableSince>=1500) {
        if(env.clearOwnGuard(request.id)!==true)return done('blocked','GUARD_OWNER_MISMATCH');
        return done('page_left','APPLICATION_READINESS_STILL_REQUIRED');
      }
    } else { stableSince=null; }
    env.sleep(250);
  }
  return done('blocked','POST_INPUT_UNCONFIRMED_NO_RETRY');
}
if(typeof module!=='undefined')module.exports={runAttempt:runAttempt};
