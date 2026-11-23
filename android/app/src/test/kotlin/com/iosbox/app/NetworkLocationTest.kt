package com.iosbox.app.core.network

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.net.InetAddress

class NetworkLocationTest {
    @Test
    fun cleartextPeerPolicyUsesResolvedAddressBytes() {
        assertTrue(NetworkLocation.isPrivateCleartextAddress(InetAddress.getByAddress(byteArrayOf(10, 1, 2, 3))))
        assertTrue(NetworkLocation.isPrivateCleartextAddress(InetAddress.getByAddress(byteArrayOf(127, 0, 0, 1))))
        assertFalse(NetworkLocation.isPrivateCleartextAddress(InetAddress.getByAddress(byteArrayOf(8, 8, 8, 8))))
        assertFalse(NetworkLocation.isPrivateCleartextAddress(InetAddress.getByAddress(byteArrayOf(0, 0, 0, 0))))
    }

    @Test
    fun detectsPrivateAndLocalHostsAccurately() {
        assertTrue(NetworkLocation.isLocalOrPrivate("http://127.0.0.1:11434/v1"))
        assertTrue(NetworkLocation.isLocalOrPrivate("http://localhost:8080/v1"))
        assertTrue(NetworkLocation.isLocalOrPrivate("http://192.168.1.100:11434/v1"))
        assertTrue(NetworkLocation.isLocalOrPrivate("http://10.0.0.5:8000/v1"))
        assertTrue(NetworkLocation.isLocalOrPrivate("http://172.16.4.2:8000/v1"))
        assertTrue(NetworkLocation.isLocalOrPrivate("http://100.64.0.1:11434/v1"))
        assertTrue(NetworkLocation.isLocalOrPrivate("http://mac-studio.local:11434/v1"))
        assertTrue(NetworkLocation.isLocalOrPrivate("http://ollama-server:11434/v1"))
        assertTrue(NetworkLocation.isLocalOrPrivate("http://[::1]:11434/v1"))
        assertTrue(NetworkLocation.isLocalOrPrivate("http://[fd00::1]:11434/v1"))
        assertTrue(NetworkLocation.isLocalOrPrivate("http://0177.0.0.1:11434/v1"))
        assertTrue(NetworkLocation.isLocalOrPrivate("http://0x7f.0.0.1:11434/v1"))
        assertTrue(NetworkLocation.isLocalOrPrivate("http://127.1:11434/v1"))
    }

    @Test
    fun rejectsPublicPlainHttpAndDoesNotMisclassifyDomainSubstrings() {
        assertFalse(NetworkLocation.isLocalOrPrivate("http://api10.example.com/v1"))
        assertFalse(NetworkLocation.isLocalOrPrivate("http://172.32.0.1/v1"))
        assertFalse(NetworkLocation.isLocalOrPrivate("https://api.openai.com/v1"))

        assertTrue(NetworkLocation.isPlainHTTPToPublicHost("http://api.openai.com/v1"))
        assertTrue(NetworkLocation.isPlainHTTPToPublicHost("http://api10.example.com/v1"))
        assertFalse(NetworkLocation.isPlainHTTPToPublicHost("https://api.openai.com/v1"))
        assertFalse(NetworkLocation.isPlainHTTPToPublicHost("http://192.168.1.10:11434/v1"))
        assertFalse(NetworkLocation.isPlainHTTPToPublicHost("http://127.0.0.1:8080/v1"))
    }
}
