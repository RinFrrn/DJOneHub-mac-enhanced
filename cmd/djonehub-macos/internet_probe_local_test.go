//go:build darwin && cgo
package main
import("testing";"time";"net";"encoding/binary";"crypto/hmac";"crypto/sha256";"fmt")
func TestLocalInternetProbe(t *testing.T){
a,e:=openDJIUSBADB();if e!=nil{t.Fatal(e)};defer a.Close()
key,e:=a.pull(voiceTestRemoteKey,32,5*time.Second);if e!=nil{t.Fatal(e)}
exchange:=func(op byte,body []byte)(byte,error){
c,e:=net.DialTimeout("tcp4",voiceDaemonAddress,3*time.Second);if e!=nil{return 0,e};defer c.Close();c.SetDeadline(time.Now().Add(8*time.Second))
h,e:=readVoiceControlFrame(c,voiceControlFrameHello);if e!=nil{return 0,e};nonce,e:=decodeVoiceDaemonHello(h);if e!=nil{return 0,e}
r,e:=encodeVoiceDaemonStatusRequest(key,nonce,1);if e!=nil{return 0,e};r=r[:20];r[6]=op;binary.BigEndian.PutUint16(r[8:10],uint16(len(body)));r=append(r,body...)
m:=hmac.New(sha256.New,key);m.Write(nonce);m.Write(r);r=append(r,m.Sum(nil)...);if _,e=c.Write(r);e!=nil{return 0,e}
f,e:=readVoiceControlFrame(c,voiceControlFrameReply);if e!=nil{return 0,e};m=hmac.New(sha256.New,key);m.Write(nonce);m.Write(f[:len(f)-32]);if !hmac.Equal(m.Sum(nil),f[len(f)-32:]){return 0,fmt.Errorf("bad tag")};if f[6]!=0{return 0,fmt.Errorf("status %d",f[6])}
p:=f[20:len(f)-32];off:=4+int(p[3])*7
for off<len(p){typ:=p[off];n:=int(binary.BigEndian.Uint16(p[off+1:]));off+=3;if typ==3&&n==1{return p[off],nil};off+=n};return 0,fmt.Errorf("no internet state")}
original,e:=exchange(1,nil);if e!=nil{t.Fatal(e)}
defer func(){_,e:=exchange(6,[]byte{original-1});if e!=nil{t.Errorf("restore failed: %v",e)}}()
state,e:=exchange(6,[]byte{0});if e!=nil||state!=1{t.Fatalf("disable %d %v",state,e)}
out,code,e:=a.shellChecked("test $(cat /proc/sys/net/ipv4/conf/bridge0/forwarding) = 0 && test $(cat /proc/sys/net/ipv6/conf/bridge0/forwarding) = 0 && echo both-forwarding-disabled",5*time.Second);t.Log(out);if e!=nil||code!=0{t.Fatal("forwarding readback failed")}
state,e=exchange(1,nil);if e!=nil||state!=1{t.Fatal("local authenticated control unavailable while disabled",e)}
state,e=exchange(6,[]byte{1});if e!=nil||state!=2{t.Fatalf("enable %d %v",state,e)}
out,code,e=a.shellChecked("cat /proc/sys/net/ipv4/conf/bridge0/forwarding; cat /proc/sys/net/ipv6/conf/bridge0/forwarding; test ! -e /usrdata/djonehub/internet-disabled",5*time.Second);t.Log(out);if e!=nil||code!=0{t.Fatal("restore readback failed")}
t.Log("Authenticated off/on and local control preservation: PASS")
}
