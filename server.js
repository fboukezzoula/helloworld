const http = require('http');
const { BlobServiceClient } = require('@azure/storage-blob');

const port = 80;

const server = http.createServer(async (request, response) => {
  response.writeHead(200, { 'Content-Type': 'text/html' });

  // Create a new BlobServiceClient with your Azure Storage account connection string
  const blobServiceClient = BlobServiceClient.fromConnectionString(process.env.AZURE_STORAGE_CONNECTION_STRING);
  // Get a reference to your Blob Container
  const containerClient = blobServiceClient.getContainerClient('showcase');

  // Get the list of blobs in the container
  const blobList = containerClient.listBlobsFlat();

  // Count the total number of blobs/files
  let count = 0;
  for await (const blob of blobList) {
    count++;
  }

  // Replace the BUILD environment variable value with the count
  process.env.BUILD = count;

  // Write the response with the updated BUILD value
  response.write(`
    <!DOCTYPE html>
    <html>
      <head>
        <title>Hello World !</title>
      </head>
      <body>
        <h1>Hello World !</h1>
        <p># number/total of the deployment for the day (docker build+tag+push and deploy to kubernetes) : ${process.env.BUILD} </p>
		<h2><b>
        <p id="countdown"></p></b></h2>
        <script>
          let timeLeft = 5
          const countdown = document.getElementById('countdown')
          const countdownInterval = setInterval(() => {
            countdown.innerText = timeLeft
            timeLeft--
            if (timeLeft < 0) {
              clearInterval(countdownInterval)
              console.log('Refreshing page...')
              location.reload()
            }
          }, 1000)
        </script>
      </body>
    </html>
  `);

  response.end();
});

server.listen(port);

