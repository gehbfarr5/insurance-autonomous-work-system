/* ES5 login-page episode gate; no credentials or input implementation. */
function createTrigger(){
 var armed=true,leftSince=null;
 return {observe:function(loginVisible,now){
  if(loginVisible!==true){
   if(leftSince===null)leftSince=now;
   if(now-leftSince>=1500)armed=true;
   return false;
  }
  leftSince=null;
  if(!armed)return false;
  armed=false;return true;
 }};
}
if(typeof module!=='undefined')module.exports={createTrigger:createTrigger};
