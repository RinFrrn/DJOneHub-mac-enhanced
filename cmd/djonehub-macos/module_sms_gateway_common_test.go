package main

import (
	"bytes"
	"crypto/hmac"
	"encoding/binary"
	"testing"
)

func smsGatewayTestMaterial() ([]byte, []byte) {
	key := make([]byte, smsControlTagBytes)
	nonce := make([]byte, smsControlNonceBytes)
	for index := range key {
		key[index] = byte(index + 1)
		nonce[index] = byte(0x80 + index)
	}
	return key, nonce
}

func TestSMSGatewayHello(t *testing.T) {
	_, nonce := smsGatewayTestMaterial()
	hello := append(smsControlHeader(smsControlFrameHello, 0, 0, smsControlNonceBytes, 0), nonce...)
	decoded, err := decodeSMSGatewayHello(hello)
	if err != nil || !bytes.Equal(decoded, nonce) {
		t.Fatalf("valid hello rejected: %v", err)
	}
	hello[7] = smsControlOpStatus
	if _, err := decodeSMSGatewayHello(hello); err == nil {
		t.Fatal("hello operation mutation accepted")
	}
}

func TestSMSGatewayStatusAuthentication(t *testing.T) {
	key, nonce := smsGatewayTestMaterial()
	request, err := encodeSMSGatewayStatusRequest(key, nonce, 42)
	if err != nil {
		t.Fatal(err)
	}
	if binary.BigEndian.Uint32(request[0:4]) != smsControlMagic || request[6] != smsControlOpStatus {
		t.Fatal("request header mismatch")
	}
	expected := smsControlTag(key, nonce, request[:smsControlHeaderBytes])
	if !hmac.Equal(expected, request[smsControlHeaderBytes:]) {
		t.Fatal("request tag mismatch")
	}
	if _, err := encodeSMSGatewayStatusRequest(key, nonce, 0); err == nil {
		t.Fatal("zero request ID accepted")
	}
}

func TestSMSGatewayStatusReply(t *testing.T) {
	key, nonce := smsGatewayTestMaterial()
	payload := []byte{1, 4, 1, 1, 0x4d, 6}
	header := smsControlHeader(smsControlFrameReply, 0, smsControlOpStatus, uint16(len(payload)), 99)
	unsigned := append(header, payload...)
	frame := append(unsigned, smsControlTag(key, nonce, unsigned)...)
	reply, err := decodeSMSGatewayStatus(key, nonce, frame, 99)
	if err != nil || reply.Status != 0 || reply.Protocol != 1 ||
		!reply.RegistrationAvailable || reply.Registration != 4 ||
		reply.IDLMajor != 1 || reply.IDLMinor != 0x4d || reply.IDLTool != 6 {
		t.Fatalf("valid reply rejected: %#v %v", reply, err)
	}
	frame[len(frame)-1] ^= 1
	if _, err := decodeSMSGatewayStatus(key, nonce, frame, 99); err == nil {
		t.Fatal("mutated reply accepted")
	}
}

func TestSMSGatewayListRoundTrip(t *testing.T) {
	key, nonce := smsGatewayTestMaterial()
	request, err := encodeSMSGatewayListRequest(key, nonce, 7, 1)
	if err != nil || request[6] != smsControlOpList || request[20] != 1 {
		t.Fatalf("LIST request invalid: %x %v", request, err)
	}
	payload := []byte{1, 0, 2, 0, 0, 0, 7, 1, 0, 0, 0, 9, 0}
	header := smsControlHeader(smsControlFrameReply, 0, smsControlOpList, uint16(len(payload)), 7)
	unsigned := append(header, payload...)
	frame := append(unsigned, smsControlTag(key, nonce, unsigned)...)
	reply, err := decodeSMSGatewayList(key, nonce, frame, 7)
	if err != nil || reply.Storage != 1 || len(reply.Messages) != 2 ||
		reply.Messages[0].Index != 7 || reply.Messages[0].Tag != 1 ||
		reply.Messages[1].Index != 9 || reply.Messages[1].Tag != 0 {
		t.Fatalf("valid LIST reply rejected: %#v %v", reply, err)
	}
	frame[len(frame)-1] ^= 1
	if _, err := decodeSMSGatewayList(key, nonce, frame, 7); err == nil {
		t.Fatal("mutated LIST reply accepted")
	}
}
