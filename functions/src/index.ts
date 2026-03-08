import { onDocumentUpdated } from "firebase-functions/v2/firestore";
import { initializeApp } from "firebase-admin/app";
import { getFirestore, FieldValue } from "firebase-admin/firestore";
import { getMessaging } from "firebase-admin/messaging";

initializeApp();

const db = getFirestore();
const messaging = getMessaging();

// Proximity threshold in meters (matches iOS LocationConstants.proximityThresholdMeters)
const PROXIMITY_THRESHOLD_METERS = 100;

// Minimum time between silent pushes to the same device (seconds)
// Prevents push storms when both devices are actively updating
const PUSH_COOLDOWN_SECONDS = 60;

// Maximum age of a peer's location (seconds) before treating it as stale.
// Prevents false proximity from old Firestore data.
const MAX_LOCATION_AGE_SECONDS = 30 * 60; // 30 minutes

// Earth radius in meters for Haversine formula
const EARTH_RADIUS_METERS = 6_371_000;

/**
 * Haversine distance between two lat/lng points in meters.
 */
function haversineDistance(
  lat1: number,
  lng1: number,
  lat2: number,
  lng2: number
): number {
  const toRad = (deg: number) => (deg * Math.PI) / 180;
  const dLat = toRad(lat2 - lat1);
  const dLng = toRad(lng2 - lng1);
  const a =
    Math.sin(dLat / 2) ** 2 +
    Math.cos(toRad(lat1)) * Math.cos(toRad(lat2)) * Math.sin(dLng / 2) ** 2;
  return 2 * EARTH_RADIUS_METERS * Math.asin(Math.sqrt(a));
}

/**
 * Triggered when a user document is updated.
 * Checks if the location fields changed, then looks for nearby connections
 * and sends silent pushes to wake their devices.
 */
export const onLocationUpdate = onDocumentUpdated(
  "users/{userId}",
  async (event) => {
    const userId = event.params.userId;
    const before = event.data?.before.data();
    const after = event.data?.after.data();

    if (!before || !after) {
      return;
    }

    // Only proceed if latitude or longitude actually changed
    if (
      before.latitude === after.latitude &&
      before.longitude === after.longitude
    ) {
      return;
    }

    const myLat = after.latitude as number | undefined;
    const myLng = after.longitude as number | undefined;
    if (myLat === undefined || myLng === undefined) {
      return;
    }

    console.log(
      `[onLocationUpdate] User ${userId} moved to (${myLat.toFixed(4)}, ${myLng.toFixed(4)})`
    );

    // Get this user's connections
    const connectionsSnap = await db
      .collection("users")
      .doc(userId)
      .collection("connections")
      .get();

    if (connectionsSnap.empty) {
      return;
    }

    const connectionUIDs = connectionsSnap.docs
      .filter((doc) => {
        const data = doc.data();
        // Skip paused connections
        return data.isPaused !== true;
      })
      .map((doc) => doc.id);

    if (connectionUIDs.length === 0) {
      return;
    }

    // Batch-read connection user documents (Firestore 'in' max 30)
    const batches: string[][] = [];
    for (let i = 0; i < connectionUIDs.length; i += 30) {
      batches.push(connectionUIDs.slice(i, i + 30));
    }

    const tokensToNotify: string[] = [];

    for (const batch of batches) {
      const usersSnap = await db
        .collection("users")
        .where("__name__", "in", batch)
        .get();

      for (const doc of usersSnap.docs) {
        const data = doc.data();
        const peerLat = data.latitude as number | undefined;
        const peerLng = data.longitude as number | undefined;
        const fcmToken = data.fcmToken as string | undefined;

        if (peerLat === undefined || peerLng === undefined || !fcmToken) {
          continue;
        }

        // Skip peers whose location is stale (older than 30 min)
        const peerLastUpdate = data.lastLocationUpdate as
          | FirebaseFirestore.Timestamp
          | undefined;
        if (peerLastUpdate) {
          const peerAge = Date.now() / 1000 - peerLastUpdate.seconds;
          if (peerAge > MAX_LOCATION_AGE_SECONDS) {
            continue;
          }
        } else {
          // No timestamp means we can't trust the location
          continue;
        }

        const distance = haversineDistance(myLat, myLng, peerLat, peerLng);

        if (distance <= PROXIMITY_THRESHOLD_METERS) {
          // Check cooldown: don't spam the peer
          const lastPush = data.lastSilentPush as
            | FirebaseFirestore.Timestamp
            | undefined;
          if (lastPush) {
            const elapsed = Date.now() / 1000 - lastPush.seconds;
            if (elapsed < PUSH_COOLDOWN_SECONDS) {
              console.log(
                `[onLocationUpdate] Skipping push to ${doc.id} — cooldown (${Math.round(elapsed)}s ago)`
              );
              continue;
            }
          }

          console.log(
            `[onLocationUpdate] ${doc.id} is ${Math.round(distance)}m away — sending silent push`
          );
          tokensToNotify.push(fcmToken);

          // Update cooldown timestamp
          await db.collection("users").doc(doc.id).update({
            lastSilentPush: FieldValue.serverTimestamp(),
          });
        }
      }
    }

    // Send silent pushes
    if (tokensToNotify.length > 0) {
      const results = await Promise.allSettled(
        tokensToNotify.map((token) =>
          messaging.send({
            token,
            apns: {
              headers: {
                "apns-priority": "5", // Silent push must use priority 5
                "apns-push-type": "background",
              },
              payload: {
                aps: {
                  "content-available": 1, // This makes it a silent push
                },
              },
            },
            data: {
              type: "location_wake",
              senderId: userId,
            },
          })
        )
      );

      results.forEach((result) => {
        if (result.status === "fulfilled") {
          console.log(`[onLocationUpdate] Silent push sent successfully`);
        } else {
          console.error(
            `[onLocationUpdate] Silent push failed: ${result.reason}`
          );
        }
      });
    }
  }
);
