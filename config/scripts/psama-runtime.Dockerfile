FROM amazoncorretto:24-alpine
COPY pic-sure-auth-services/target/pic-sure-auth-services-*.jar /pic-sure-auth-service.jar
EXPOSE 8090
ENTRYPOINT ["sh", "-c", "java ${JAVA_OPTS} -jar /pic-sure-auth-service.jar"]
