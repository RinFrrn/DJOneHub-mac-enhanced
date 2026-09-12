package main

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/binary"
	"errors"
	"fmt"
)

const (
	smsControlMagic        = 0x444a4f53
	smsControlVersion      = 1
	smsControlFrameHello   = 1
	smsControlFrameRequest = 2
	smsControlFrameReply   = 3
	smsControlOpStatus     = 1
	smsControlOpList       = 2
	smsControlHeaderBytes  = 20
	smsControlNonceBytes   = 32
	smsControlTagBytes     = 32
	smsControlMaxResponse  = 1024
)

type smsGatewayStatus struct {
	Status                byte `json:"status"`
	Protocol              byte `json:"protocol,omitempty"`
	Registration          byte `json:"registration,omitempty"`
	RegistrationAvailable bool `json:"registration_available"`
	IDLMajor              byte `json:"idl_major,omitempty"`
	IDLMinor              byte `json:"idl_minor,omitempty"`
	IDLTool               byte `json:"idl_tool,omitempty"`
}

type smsGatewayMessageRef struct {
	Index uint32 `json:"index"`
	Tag   byte   `json:"tag"`
}

type smsGatewayList struct {
	Status   byte                   `json:"status"`
	Storage  byte                   `json:"storage"`
	Messages []smsGatewayMessageRef `json:"messages,omitempty"`
}

func smsControlHeader(frameType, code, operation byte, payloadLength uint16, requestID uint64) []byte {
	header := make([]byte, smsControlHeaderBytes)
	binary.BigEndian.PutUint32(header[0:4], smsControlMagic)
	header[4] = smsControlVersion
	header[5] = frameType
	header[6] = code
	header[7] = operation
	binary.BigEndian.PutUint16(header[8:10], payloadLength)
	binary.BigEndian.PutUint64(header[12:20], requestID)
	return header
}

func smsControlTag(key, nonce, frame []byte) []byte {
	mac := hmac.New(sha256.New, key)
	_, _ = mac.Write(nonce)
	_, _ = mac.Write(frame)
	return mac.Sum(nil)
}

func decodeSMSGatewayHello(frame []byte) ([]byte, error) {
	if len(frame) != smsControlHeaderBytes+smsControlNonceBytes ||
		binary.BigEndian.Uint32(frame[0:4]) != smsControlMagic ||
		frame[4] != smsControlVersion || frame[5] != smsControlFrameHello ||
		frame[6] != 0 || frame[7] != 0 ||
		binary.BigEndian.Uint16(frame[8:10]) != smsControlNonceBytes ||
		frame[10] != 0 || frame[11] != 0 ||
		binary.BigEndian.Uint64(frame[12:20]) != 0 {
		return nil, errors.New("SMS gateway challenge 帧无效")
	}
	return append([]byte(nil), frame[smsControlHeaderBytes:]...), nil
}

func encodeSMSGatewayStatusRequest(key, nonce []byte, requestID uint64) ([]byte, error) {
	if len(key) != smsControlTagBytes || len(nonce) != smsControlNonceBytes || requestID == 0 {
		return nil, errors.New("SMS gateway STATUS 请求参数无效")
	}
	header := smsControlHeader(smsControlFrameRequest, smsControlOpStatus, 0, 0, requestID)
	return append(header, smsControlTag(key, nonce, header)...), nil
}

func encodeSMSGatewayListRequest(key, nonce []byte, requestID uint64, storage byte) ([]byte, error) {
	if len(key) != smsControlTagBytes || len(nonce) != smsControlNonceBytes ||
		requestID == 0 || storage > 1 {
		return nil, errors.New("SMS gateway LIST 请求参数无效")
	}
	header := smsControlHeader(smsControlFrameRequest, smsControlOpList, 0, 1, requestID)
	unsigned := append(header, storage)
	return append(unsigned, smsControlTag(key, nonce, unsigned)...), nil
}

func decodeSMSGatewayStatus(key, nonce, frame []byte, expectedRequestID uint64) (smsGatewayStatus, error) {
	var reply smsGatewayStatus
	if len(key) != smsControlTagBytes || len(nonce) != smsControlNonceBytes ||
		len(frame) < smsControlHeaderBytes+smsControlTagBytes ||
		binary.BigEndian.Uint32(frame[0:4]) != smsControlMagic ||
		frame[4] != smsControlVersion || frame[5] != smsControlFrameReply ||
		frame[7] != smsControlOpStatus || frame[10] != 0 || frame[11] != 0 ||
		binary.BigEndian.Uint64(frame[12:20]) != expectedRequestID {
		return reply, errors.New("SMS gateway STATUS 响应头无效")
	}
	payloadLength := int(binary.BigEndian.Uint16(frame[8:10]))
	if payloadLength > smsControlMaxResponse ||
		len(frame) != smsControlHeaderBytes+payloadLength+smsControlTagBytes {
		return reply, errors.New("SMS gateway STATUS 响应长度无效")
	}
	unsignedLength := smsControlHeaderBytes + payloadLength
	expectedTag := smsControlTag(key, nonce, frame[:unsignedLength])
	if !hmac.Equal(expectedTag, frame[unsignedLength:]) {
		return reply, errors.New("SMS gateway STATUS 响应认证失败")
	}
	reply.Status = frame[6]
	if reply.Status != 0 {
		if payloadLength != 0 {
			return smsGatewayStatus{}, errors.New("SMS gateway 错误响应包含 payload")
		}
		return reply, nil
	}
	if payloadLength != 6 {
		return smsGatewayStatus{}, fmt.Errorf("SMS gateway STATUS payload 长度无效: %d", payloadLength)
	}
	payload := frame[smsControlHeaderBytes:unsignedLength]
	reply.Protocol = payload[0]
	reply.Registration = payload[1]
	reply.RegistrationAvailable = payload[2] == 1
	if payload[2] > 1 || payload[3] == 0 {
		return smsGatewayStatus{}, errors.New("SMS gateway STATUS payload 字段无效")
	}
	reply.IDLMajor = payload[3]
	reply.IDLMinor = payload[4]
	reply.IDLTool = payload[5]
	return reply, nil
}

func decodeSMSGatewayList(key, nonce, frame []byte, expectedRequestID uint64) (smsGatewayList, error) {
	var reply smsGatewayList
	if len(key) != smsControlTagBytes || len(nonce) != smsControlNonceBytes ||
		len(frame) < smsControlHeaderBytes+smsControlTagBytes ||
		binary.BigEndian.Uint32(frame[0:4]) != smsControlMagic ||
		frame[4] != smsControlVersion || frame[5] != smsControlFrameReply ||
		frame[7] != smsControlOpList || frame[10] != 0 || frame[11] != 0 ||
		binary.BigEndian.Uint64(frame[12:20]) != expectedRequestID {
		return reply, errors.New("SMS gateway LIST 响应头无效")
	}
	payloadLength := int(binary.BigEndian.Uint16(frame[8:10]))
	if payloadLength > smsControlMaxResponse ||
		len(frame) != smsControlHeaderBytes+payloadLength+smsControlTagBytes {
		return reply, errors.New("SMS gateway LIST 响应长度无效")
	}
	unsignedLength := smsControlHeaderBytes + payloadLength
	if !hmac.Equal(smsControlTag(key, nonce, frame[:unsignedLength]), frame[unsignedLength:]) {
		return reply, errors.New("SMS gateway LIST 响应认证失败")
	}
	reply.Status = frame[6]
	if reply.Status != 0 {
		if payloadLength != 0 {
			return smsGatewayList{}, errors.New("SMS gateway LIST 错误响应包含 payload")
		}
		return reply, nil
	}
	if payloadLength < 3 || (payloadLength-3)%5 != 0 {
		return smsGatewayList{}, errors.New("SMS gateway LIST payload 长度无效")
	}
	payload := frame[smsControlHeaderBytes:unsignedLength]
	reply.Storage = payload[0]
	count := int(binary.BigEndian.Uint16(payload[1:3]))
	if count != (payloadLength-3)/5 || count > 128 || reply.Storage > 1 {
		return smsGatewayList{}, errors.New("SMS gateway LIST 计数或存储字段无效")
	}
	reply.Messages = make([]smsGatewayMessageRef, 0, count)
	for index := 0; index < count; index++ {
		record := payload[3+index*5 : 8+index*5]
		if record[4] > 3 {
			return smsGatewayList{}, errors.New("SMS gateway LIST tag 无效")
		}
		reply.Messages = append(reply.Messages, smsGatewayMessageRef{
			Index: binary.BigEndian.Uint32(record[0:4]),
			Tag:   record[4],
		})
	}
	return reply, nil
}
